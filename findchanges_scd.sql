-- ============================================================================
-- Procedure: [dbo].[FindChanges_SCD]
-- Description: Detects row-level changes (inserts, updates, deletes) in a
--              Microsoft Fabric Data Warehouse or Fabric SQL Analytics Endpoint
--              table between two points in time, and maintains a Type 2 Slowly
--              Changing Dimension (SCD) table with full history.
--
-- Platform:    Microsoft Fabric Data Warehouse (T-SQL subset)
--              Uses: INFORMATION_SCHEMA.COLUMNS, STRING_AGG, EXEC(), OBJECT_ID,
--                    QUOTENAME, PARSENAME, SELECT INTO, UPDATE FROM JOIN
--              All constructs validated against Fabric DW T-SQL surface area.
--
-- Parameters:
--   @tablename  - Fully qualified table name, e.g. '[dbo].[foo2]'
--   @keycolumn  - Business key column name, e.g. 'ProductID'
--   @startdt    - Start timestamp in ISO 8601 format (the "before" snapshot)
--   @enddt      - End timestamp in ISO 8601 format (the "after" snapshot)
--
-- How it works:
--   1. Snapshots the table at @startdt and @enddt using time-travel.
--   2. Uses the business key (@keycolumn) to classify changes:
--        - NEW:     key exists in end snapshot but not in start snapshot
--        - DELETED: key exists in start snapshot but not in end snapshot
--        - UPDATED: key exists in both but non-key columns differ
--   3. Dynamically creates the SCD table from INFORMATION_SCHEMA.COLUMNS
--      if it does not already exist, with columns:
--        - All source columns (preserving data types and precision)
--        - _SCD_StartDate   (DATETIME2) - when this version became active
--        - _SCD_EndDate     (DATETIME2) - when this version was superseded (NULL = current)
--        - _SCD_DeletedFlag (BIT)       - 1 if the row was deleted
--        - _SCD_LastUpdated (DATETIME2) - last time this SCD record was modified
--   4. Applies changes to the SCD table:
--        - UPDATED: closes old record (sets EndDate), inserts new version
--        - DELETED: closes record (sets EndDate, DeletedFlag = 1)
--        - NEW:     inserts new record with StartDate = @enddt
--
-- Notes:
--   - The business key column must uniquely identify rows in the source table.
--   - Requires time-travel support (Fabric DW / SQL Analytics Endpoint).
--   - Updated rows appear as two SCD records: the closed old version and the
--     new active version, preserving full history.
-- ============================================================================
CREATE PROCEDURE [dbo].[FindChanges_SCD]
    @tablename  VARCHAR(50),   -- Target table name (schema-qualified)
    @keycolumn  VARCHAR(50),   -- Business key column name
    @startdt    VARCHAR(26),   -- Start point-in-time timestamp
    @enddt      VARCHAR(26)    -- End point-in-time timestamp
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sSQL       VARCHAR(MAX);
    DECLARE @schema     SYSNAME;
    DECLARE @table      SYSNAME;
    DECLARE @scdtable   VARCHAR(200);
    DECLARE @collist    VARCHAR(MAX);  -- Comma-separated list of source column names
    DECLARE @coldefs    VARCHAR(MAX);  -- Column definitions for CREATE TABLE

    -- ========================================================================
    -- STEP 0: Parse and validate table/schema names
    --         e.g. [dbo].[foo2] → schema='dbo', table='foo2'
    --         SCD table → [dbo].[foo2_SCD]
    -- ========================================================================
    SET @schema = PARSENAME(REPLACE(REPLACE(@tablename, '[', ''), ']', ''), 2);
    SET @table  = PARSENAME(REPLACE(REPLACE(@tablename, '[', ''), ']', ''), 1);

    -- Default to 'dbo' schema if not specified
    IF @schema IS NULL SET @schema = 'dbo';

    SET @scdtable = QUOTENAME(@schema) + '.' + QUOTENAME(@table + '_SCD');

    PRINT 'Source table: ' + @tablename;
    PRINT 'SCD table:    ' + @scdtable;
    PRINT 'Key column:   ' + @keycolumn;

    -- ========================================================================
    -- STEP 0b: Build column metadata from INFORMATION_SCHEMA.COLUMNS
    --          This dynamically generates:
    --            @collist - for INSERT/SELECT (e.g. "[Col1],[Col2],[Col3]")
    --            @coldefs - for CREATE TABLE (e.g. "[Col1] INT NULL, [Col2] VARCHAR(50) NULL")
    -- ========================================================================

    -- Build the column name list (used in INSERT INTO ... SELECT statements)
    -- NOTE: Column order does not need to be ordinal as long as the same @collist
    --       is used consistently in INSERT and SELECT statements.
    SELECT @collist = STRING_AGG(QUOTENAME(COLUMN_NAME), ',')
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = @schema
      AND TABLE_NAME = @table;

    IF @collist IS NULL
    BEGIN
        RAISERROR('Source table not found or has no columns: %s', 16, 1, @tablename);
        RETURN;
    END

    -- Build the column definitions for CREATE TABLE
    -- Handles: varchar/nvarchar/char/nchar with length, decimal/numeric with precision/scale,
    --          datetime2/time/datetimeoffset with scale, varbinary with length, and all other types
    -- NOTE: DATETIME_PRECISION returns NULL in Fabric DW, so we default to 6
    --       (microsecond precision) when it is not available.
    SELECT @coldefs = STRING_AGG(
        QUOTENAME(COLUMN_NAME) + ' ' +
        DATA_TYPE +
        CASE
            -- Character and binary types with length (-1 means MAX)
            WHEN DATA_TYPE IN ('varchar','nvarchar','char','nchar','varbinary')
                THEN '(' + CASE WHEN CHARACTER_MAXIMUM_LENGTH = -1 THEN 'MAX'
                           ELSE CAST(CHARACTER_MAXIMUM_LENGTH AS VARCHAR(10)) END + ')'
            -- Numeric types with precision and scale
            WHEN DATA_TYPE IN ('decimal','numeric')
                THEN '(' + CAST(NUMERIC_PRECISION AS VARCHAR(10)) + ','
                         + CAST(NUMERIC_SCALE AS VARCHAR(10)) + ')'
            -- Date/time types with fractional seconds precision
            -- Fabric DW may return NULL for DATETIME_PRECISION; default to 6
            WHEN DATA_TYPE IN ('datetime2','time','datetimeoffset')
                THEN '(' + CAST(COALESCE(DATETIME_PRECISION, 6) AS VARCHAR(10)) + ')'
            ELSE ''
        END +
        CASE WHEN IS_NULLABLE = 'YES' THEN ' NULL' ELSE ' NOT NULL' END,
        ', '
    )
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = @schema
      AND TABLE_NAME = @table;

    PRINT 'Source columns: ' + @collist;

    -- ========================================================================
    -- STEP 1: Create time-travel snapshots (before and after)
    -- ========================================================================

    -- Clean up any previous staging tables
    IF OBJECT_ID(N'[dbo].[Orginal_tbl]', N'U') IS NOT NULL
        DROP TABLE [dbo].[Orginal_tbl];

    IF OBJECT_ID(N'[dbo].[new_tbl]', N'U') IS NOT NULL
        DROP TABLE [dbo].[new_tbl];

    -- Snapshot at START time (the "before" state)
    SET @sSQL = 'SELECT * INTO [dbo].[Orginal_tbl] FROM ' + @tablename
              + ' AS DC OPTION (FOR TIMESTAMP AS OF ''' + @startdt + ''');';
    PRINT @sSQL;
    EXEC(@sSQL);

    -- Snapshot at END time (the "after" state)
    SET @sSQL = 'SELECT * INTO [dbo].[new_tbl] FROM ' + @tablename
              + ' AS DC OPTION (FOR TIMESTAMP AS OF ''' + @enddt + ''');';
    PRINT @sSQL;
    EXEC(@sSQL);

    -- ========================================================================
    -- STEP 2: Classify changes using the business key
    --   - Deleted rows:  key in Orginal_tbl but NOT in new_tbl
    --   - New rows:      key in new_tbl but NOT in Orginal_tbl
    --   - Updated rows:  key in both, but full row differs (EXCEPT finds them)
    -- ========================================================================

    -- Clean up classification staging tables
    IF OBJECT_ID(N'[dbo].[scd_deleted]', N'U') IS NOT NULL
        DROP TABLE [dbo].[scd_deleted];

    IF OBJECT_ID(N'[dbo].[scd_new]', N'U') IS NOT NULL
        DROP TABLE [dbo].[scd_new];

    IF OBJECT_ID(N'[dbo].[scd_updated]', N'U') IS NOT NULL
        DROP TABLE [dbo].[scd_updated];

    -- DELETED: rows whose key exists in old snapshot but not in new
    SET @sSQL = 'SELECT o.* INTO [dbo].[scd_deleted] FROM [dbo].[Orginal_tbl] o '
              + 'WHERE NOT EXISTS (SELECT 1 FROM [dbo].[new_tbl] n WHERE n.'
              + QUOTENAME(@keycolumn) + ' = o.' + QUOTENAME(@keycolumn) + ');';
    PRINT @sSQL;
    EXEC(@sSQL);

    -- NEW: rows whose key exists in new snapshot but not in old
    SET @sSQL = 'SELECT n.* INTO [dbo].[scd_new] FROM [dbo].[new_tbl] n '
              + 'WHERE NOT EXISTS (SELECT 1 FROM [dbo].[Orginal_tbl] o WHERE o.'
              + QUOTENAME(@keycolumn) + ' = n.' + QUOTENAME(@keycolumn) + ');';
    PRINT @sSQL;
    EXEC(@sSQL);

    -- UPDATED: rows whose key exists in both but the full row content differs
    -- Uses EXCEPT to detect any column change (handles NULLs correctly)
    SET @sSQL = 'SELECT n.* INTO [dbo].[scd_updated] FROM [dbo].[new_tbl] n '
              + 'WHERE EXISTS (SELECT 1 FROM [dbo].[Orginal_tbl] o WHERE o.'
              + QUOTENAME(@keycolumn) + ' = n.' + QUOTENAME(@keycolumn) + ') '
              + 'AND EXISTS ('
              + '  SELECT * FROM (SELECT * FROM [dbo].[Orginal_tbl] WHERE '
              + QUOTENAME(@keycolumn) + ' = n.' + QUOTENAME(@keycolumn)
              + '  EXCEPT SELECT * FROM [dbo].[new_tbl] WHERE '
              + QUOTENAME(@keycolumn) + ' = n.' + QUOTENAME(@keycolumn)
              + ') diff);';
    PRINT @sSQL;
    EXEC(@sSQL);

    -- ========================================================================
    -- STEP 3: Dynamically create the SCD table if it doesn't exist
    --         Uses column definitions built from INFORMATION_SCHEMA.COLUMNS
    --         Adds 4 SCD metadata columns with explicit types
    -- ========================================================================
    IF OBJECT_ID(@scdtable, N'U') IS NULL
    BEGIN
        -- Dynamically build CREATE TABLE with source columns + SCD metadata columns
        SET @sSQL = 'CREATE TABLE ' + @scdtable + ' ('
                  + @coldefs + ', '
                  + '[_SCD_StartDate] DATETIME2(6) NULL, '
                  + '[_SCD_EndDate] DATETIME2(6) NULL, '
                  + '[_SCD_DeletedFlag] BIT NOT NULL, '
                  + '[_SCD_LastUpdated] DATETIME2(6) NULL'
                  + ');';
        PRINT 'Creating SCD table: ' + @sSQL;
        EXEC(@sSQL);

        -- Seed the SCD table with the initial snapshot (start time = baseline)
        -- All rows from the start snapshot become the first active version
        SET @sSQL = 'INSERT INTO ' + @scdtable + ' (' + @collist
                  + ', [_SCD_StartDate], [_SCD_EndDate], [_SCD_DeletedFlag], [_SCD_LastUpdated]) '
                  + 'SELECT ' + @collist + ', '
                  + 'CAST(''' + @startdt + ''' AS DATETIME2), '  -- _SCD_StartDate
                  + 'NULL, '                                      -- _SCD_EndDate (current)
                  + '0, '                                         -- _SCD_DeletedFlag
                  + 'CAST(''' + @startdt + ''' AS DATETIME2) '   -- _SCD_LastUpdated
                  + 'FROM [dbo].[Orginal_tbl];';
        PRINT 'Seeding SCD table: ' + @sSQL;
        EXEC(@sSQL);
    END

    -- ========================================================================
    -- STEP 4: Apply changes to the SCD table
    -- ========================================================================

    -- 4a. UPDATED rows: Close the current active record and insert new version
    -- Close existing active record by setting the EndDate
    SET @sSQL = 'UPDATE scd SET '
              + '[_SCD_EndDate] = CAST(''' + @enddt + ''' AS DATETIME2), '
              + '[_SCD_LastUpdated] = CAST(''' + @enddt + ''' AS DATETIME2) '
              + 'FROM ' + @scdtable + ' scd '
              + 'INNER JOIN [dbo].[scd_updated] u ON scd.' + QUOTENAME(@keycolumn)
              + ' = u.' + QUOTENAME(@keycolumn) + ' '
              + 'WHERE scd.[_SCD_EndDate] IS NULL;';
    PRINT 'Closing updated records: ' + @sSQL;
    EXEC(@sSQL);

    -- Insert the new version of updated rows as active records
    SET @sSQL = 'INSERT INTO ' + @scdtable + ' (' + @collist
              + ', [_SCD_StartDate], [_SCD_EndDate], [_SCD_DeletedFlag], [_SCD_LastUpdated]) '
              + 'SELECT ' + @collist + ', '
              + 'CAST(''' + @enddt + ''' AS DATETIME2), '  -- _SCD_StartDate
              + 'NULL, '                                    -- _SCD_EndDate (current)
              + '0, '                                       -- _SCD_DeletedFlag
              + 'CAST(''' + @enddt + ''' AS DATETIME2) '   -- _SCD_LastUpdated
              + 'FROM [dbo].[scd_updated];';
    PRINT 'Inserting updated records: ' + @sSQL;
    EXEC(@sSQL);

    -- 4b. DELETED rows: Close the current active record and mark as deleted
    SET @sSQL = 'UPDATE scd SET '
              + '[_SCD_EndDate] = CAST(''' + @enddt + ''' AS DATETIME2), '
              + '[_SCD_DeletedFlag] = 1, '
              + '[_SCD_LastUpdated] = CAST(''' + @enddt + ''' AS DATETIME2) '
              + 'FROM ' + @scdtable + ' scd '
              + 'INNER JOIN [dbo].[scd_deleted] d ON scd.' + QUOTENAME(@keycolumn)
              + ' = d.' + QUOTENAME(@keycolumn) + ' '
              + 'WHERE scd.[_SCD_EndDate] IS NULL;';
    PRINT 'Closing deleted records: ' + @sSQL;
    EXEC(@sSQL);

    -- 4c. NEW rows: Insert as new active records
    SET @sSQL = 'INSERT INTO ' + @scdtable + ' (' + @collist
              + ', [_SCD_StartDate], [_SCD_EndDate], [_SCD_DeletedFlag], [_SCD_LastUpdated]) '
              + 'SELECT ' + @collist + ', '
              + 'CAST(''' + @enddt + ''' AS DATETIME2), '  -- _SCD_StartDate
              + 'NULL, '                                    -- _SCD_EndDate (current)
              + '0, '                                       -- _SCD_DeletedFlag
              + 'CAST(''' + @enddt + ''' AS DATETIME2) '   -- _SCD_LastUpdated
              + 'FROM [dbo].[scd_new];';
    PRINT 'Inserting new records: ' + @sSQL;
    EXEC(@sSQL);

    -- ========================================================================
    -- STEP 5: Output summary of changes detected
    -- ========================================================================
    SET @sSQL = 'SELECT ''Deleted'' AS [action], * FROM [dbo].[scd_deleted] '
              + 'UNION ALL '
              + 'SELECT ''Updated'' AS [action], * FROM [dbo].[scd_updated] '
              + 'UNION ALL '
              + 'SELECT ''New'' AS [action], * FROM [dbo].[scd_new];';
    EXEC(@sSQL);

    -- ========================================================================
    -- STEP 6: Clean up staging tables
    -- ========================================================================
    DROP TABLE [dbo].[Orginal_tbl];
    DROP TABLE [dbo].[new_tbl];
    DROP TABLE [dbo].[scd_deleted];
    DROP TABLE [dbo].[scd_new];
    DROP TABLE [dbo].[scd_updated];

    PRINT 'FindChanges_SCD completed successfully.';
END;

