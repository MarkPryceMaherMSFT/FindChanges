-- ============================================================================
-- Procedure: [dbo].[FindChanges]
-- Description: Detects row-level changes (inserts, updates, deletes) in a
--              Microsoft Fabric Data Warehouse or Fabric SQL Analytics Endpoint
--              table between two points in time using time-travel
--              (FOR TIMESTAMP AS OF).
--
-- Parameters:
--   @tablename  - Fully qualified table name, e.g. '[dbo].[foo2]'
--   @startdt    - Start timestamp in ISO 8601 format (the "before" snapshot)
--   @enddt      - End timestamp in ISO 8601 format (the "after" snapshot)
--
-- How it works:
--   1. Snapshots the table at @startdt into a temporary staging table.
--   2. Snapshots the table at @enddt into a second staging table.
--   3. Uses EXCEPT set operations to identify:
--        - Rows present in the original but missing from the new  → 'Removed'
--        - Rows present in the new but missing from the original  → 'Inserted/Updated'
--   4. Returns a combined result set with an 'action' column.
--
-- Notes:
--   - Updated rows appear as both 'Removed' (old version) and
--     'Inserted/Updated' (new version) because EXCEPT compares full rows.
--   - Requires time-travel support (Fabric DW / SQL Analytics Endpoint).
-- ============================================================================
CREATE PROCEDURE [dbo].[FindChanges]
    @tablename VARCHAR(50),   -- Target table name (schema-qualified)
    @startdt   VARCHAR(26),   -- Start point-in-time timestamp
    @enddt     VARCHAR(26)    -- End point-in-time timestamp
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sSQL VARCHAR(MAX);

    -- Clean up any previous staging tables from prior executions
    IF OBJECT_ID(N'[dbo].[Orginal_tbl]', N'U') IS NOT NULL
    BEGIN
        DROP TABLE [dbo].[Orginal_tbl];
    END

    IF OBJECT_ID(N'[dbo].[new_tbl]', N'U') IS NOT NULL
    BEGIN
        DROP TABLE [dbo].[new_tbl];
    END

    -- Snapshot the table at the START timestamp into [dbo].[Orginal_tbl]
    SET @sSQL = 'SELECT * INTO Orginal_tbl FROM ' + @tablename
              + ' AS DC OPTION (FOR TIMESTAMP AS OF ''' + @startdt + ''');';
    PRINT @sSQL;
    EXEC(@sSQL);

    -- Snapshot the table at the END timestamp into [dbo].[new_tbl]
    SET @sSQL = 'SELECT * INTO new_tbl FROM ' + @tablename
              + ' AS DC OPTION (FOR TIMESTAMP AS OF ''' + @enddt + ''');';
    PRINT @sSQL;
    EXEC(@sSQL);

    -- Compare the two snapshots using EXCEPT to find differences:
    --   Rows in original but NOT in new  → deleted rows ('Removed')
    --   Rows in new but NOT in original  → inserted or updated rows ('Inserted/Updated')
    SELECT 'Removed' AS action, *
    FROM (SELECT * FROM Orginal_tbl EXCEPT SELECT * FROM new_tbl) a
    UNION
    SELECT 'Inserted/Updated' AS action, *
    FROM (SELECT * FROM new_tbl EXCEPT SELECT * FROM Orginal_tbl) b;

END;