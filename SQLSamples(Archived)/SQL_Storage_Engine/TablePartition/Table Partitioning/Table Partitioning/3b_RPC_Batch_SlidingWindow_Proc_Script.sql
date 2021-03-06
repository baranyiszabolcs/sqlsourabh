Use PartitionDemoDB
Go

/****** Object:  StoredProcedure [dbo].[RPC_Batch_Sliding_Window]    Script Date: 7/22/2013 3:30:02 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
Alter Procedure [dbo].[Partition_Sliding_Window]
As
Set XACT_ABORT ON
declare @day int = datepart(day, getdate())
--If (@day = 15 or @day = 8 or @day=22 or @day = Datepart(day, EOMONTH(getdate())))
--	begin
----- Truncate the SwapTable
			Select 'Truncating the Swap Info Table'
			Truncate Table dbo.PartitionSwap

--- Populate the SwapTable with the required data	
			Select 'Populating the Swap Info Table'		
			INSERT INTO dbo.PartitionSwap (PartitionTable, PartitionSchemeName, PartitionFunction, PartitionNumber, PartitionRows, FileGroupName)
			SELECT DISTINCT 
				OBJECT_NAME(SI.object_id) AS PartitionedTable
				, DS.name AS PartitionSchemeName
				, PF.name AS PartitionFunction
				, P.partition_number AS PartitionNumber
				, P.rows AS PartitionRows
				, FG.name AS FileGroupName
			FROM sys.partitions AS P
			JOIN sys.indexes AS SI
				ON P.object_id = SI.object_id AND P.index_id = SI.index_id 
			JOIN sys.data_spaces AS DS
				ON DS.data_space_id = SI.data_space_id
			JOIN sys.partition_schemes AS PS
				ON PS.data_space_id = SI.data_space_id
			JOIN sys.partition_functions AS PF
				ON PF.function_id = PS.function_id 
			JOIN sys.destination_data_spaces AS DDS
				ON DDS.partition_scheme_id = SI.data_space_id 
				AND DDS.destination_id = P.partition_number
			JOIN sys.filegroups AS FG
				ON DDS.data_space_id = FG.data_space_id
			WHERE DS.type = 'PS'
			AND DS.name like 'StartTime_PartitionSchema'
			AND P.partition_number = 1
			AND OBJECTPROPERTYEX(SI.object_id, 'BaseType') = 'U'
			AND SI.type IN(0,1);


---- Drop Staging Table, if it exists.
			IF (EXISTS (SELECT * 
							 FROM INFORMATION_SCHEMA.TABLES 
							 WHERE TABLE_SCHEMA = 'dbo' 
							 AND  TABLE_NAME = 'RPC_Batch_Completed_Data_Staging')) 
			BEGIN
					Select ' Partition Staging Table already exists, Dropping the Table.'
					DROP TABLE dbo.RPC_Batch_Completed_Data_Staging		 	 
			END
	
--- Create Staging Table using Powershell, need to call xp_cmdshell, using try catch block for safety.		
			Select 'Creating Stating Table'
			Begin Try
				exec xp_cmdshell 'powershell.exe -file "C:\KAAM\CustomerData\ColumbiaAsia\RPC_Batch_Create_Staging_Table.ps1"'
				Select 'Creating Stating Table'
			End Try
			begin Catch
				Select 'Creation of Staging Table Failed with Error ' + ERROR_MESSAGE()
				ROLLBACK;
			end Catch				

--- Perform the Partition Switch.
			Select 'Perforing the Partition Switch'
			If(EXISTS (SELECT * 
							 FROM INFORMATION_SCHEMA.TABLES 
							 WHERE TABLE_SCHEMA = 'dbo' 
							 AND  TABLE_NAME = 'RPC_Batch_Completed_Data_Staging'))
			begin
				begin try
		--- Switch the Parttion to the Staging table.
					ALTER TABLE [dbo].[RPC_Batch_COmpleted_Data] SWITCH PARTITION 1 TO [dbo].[RPC_Batch_Completed_Data_Staging];
					Select 'Partition Switch Succeeded'

		-- Mark the next file group to be used.	
					Begin Try
						Select 'Marking the Next Used Filegroup'
						DECLARE @MergeVal datetime, @FileGroup varchar(200), @SQLStmt nvarchar(max), @BoundaryID int
						SET @BoundaryID = 1
						
						SELECT @MergeVal = CAST(value as datetime)  
						FROM SYS.PARTITION_RANGE_VALUES prv
						INNER JOIN SYS.partition_functions pf ON prv.function_id=pf.function_id
						WHERE name like 'StartTime_PartitionFunction'
						AND boundary_id = @BoundaryID
						SELECT @MergeVal

						Select 'Performing the Partition Merge'
						ALTER PARTITION FUNCTION StartTime_PartitionFunction() MERGE RANGE (@MergeVal)
						Select 'Partition Merge Succeeded'

						SELECT @FileGroup = FileGroupName 
						FROM dbo.PartitionSwap
						WHERE PartitionSchemeName = 'StartTime_PartitionSchema'
						AND PartitionNumber = @BoundaryID

						SET @SQLStmt = 'ALTER PARTITION SCHEME StartTime_PartitionSchema NEXT USED ['+ @FileGroup + ']'
						EXEC sp_executeSQL @SQLStmt

						Select 'The FileGroup ' + @FileGroup + ' has been marked for next use'
					End Try
					Begin Catch
						Select 'Next Use Filegroup could not be marked, error was ' + ERROR_MESSAGE()
							ROLLBACK;
					End Catch

	--- Perform the Partition Split
					begin Try
						Select 'Performing Partition Split'
							DECLARE @NewPart datetime
							declare @maxdate datetime
							Select @maxdate = MAX(CAST(value as datetime)) from sys.partition_range_values rv
							JOIN sys.partition_functions pf on rv.function_id = pf.function_id
							where pf.name like 'StartTime_PartitionFunction' 
							SELECT  @NewPart =  
									case 
										when (datepart(day,@maxdate) <= 8) then DATETIMEFROMPARTS(datepart(year,@maxdate),datepart(month,@maxdate),15,23,59,59,997)
										when (datepart(day,@maxdate) > 8 and datepart(day,@maxdate) <= 15) then DATETIMEFROMPARTS(datepart(year,@maxdate),datepart(month,@maxdate),22,23,59,59,997)
										when (datepart(day,@maxdate) > 15 and datepart(day,@maxdate) <= 22) then DATETIMEFROMPARTS(datepart(year,@maxdate),datepart(month,@maxdate),DATEPART(day,EOMONTH(@maxdate)),23,59,59,997)
										else DATETIMEFROMPARTS(datepart(year,@maxdate),datepart(month,@maxdate)+1,8,23,59,59,997)
									end
							IF @NewPart IS NOT NULL
							BEGIN
								ALTER PARTITION FUNCTION StartTime_PartitionFunction() SPLIT RANGE (@NewPart)
								--Select @NewPart
								Select 'Partition Split Completed successfully'
							END
					End Try
					Begin Catch
							Select 'Partition Split encountered an error ' + ERROR_MESSAGE()
							ROLLBACK;
					End Catch
				end Try
				Begin Catch
						Select 'Partition Switch Failed with Error ' + ERROR_MESSAGE()
						ROLLBACK;
				end catch
			end
			Else
			begin
				Select 'The staging Table is missing, sliding window cannot proceed'
			end
    --END
--ELSE
--	BEGIN
--		Select 'Sliding Window can only	be performed on the 8th, 15th, 22nd or last day of each month'
--	END
