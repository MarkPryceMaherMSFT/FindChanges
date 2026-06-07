-- ============================================================================
-- TEST SCRIPT: [dbo].[FindChanges_SCD]
-- Description: End-to-end demo showing how to create a test table, make
--              changes, and use FindChanges_SCD to detect and track them
--              in a Type 2 Slowly Changing Dimension table.
--
-- Prerequisites:
--   - Microsoft Fabric Data Warehouse or SQL Analytics Endpoint
--   - The [dbo].[FindChanges_SCD] procedure has been created
--     (see findchanges_scd.sql)
--   - Time-travel retention is available (default in Fabric)
--
-- IMPORTANT: This script uses WAITFOR DELAY to allow time between operations
--            so that time-travel can distinguish the snapshots. In production,
--            you would use known timestamps from your ETL pipeline or logs.
-- ============================================================================

-- ============================================================================
-- STEP 1: Create a test table with sample data
-- ============================================================================
PRINT '=== STEP 1: Creating test table [dbo].[Customers] ===';

IF OBJECT_ID(N'[dbo].[Customers]', N'U') IS NOT NULL
    DROP TABLE [dbo].[Customers];

-- Drop the SCD table too if it exists from a previous run
IF OBJECT_ID(N'[dbo].[Customers_SCD]', N'U') IS NOT NULL
    DROP TABLE [dbo].[Customers_SCD];

CREATE TABLE [dbo].[Customers]
(
    CustomerID   INT          NOT NULL,
    FullName     VARCHAR(100) NOT NULL,
    Email        VARCHAR(150) NOT NULL,
    City         VARCHAR(50)  NOT NULL,
    MemberTier   VARCHAR(20)  NOT NULL
);

-- Insert initial data
INSERT INTO [dbo].[Customers] (CustomerID, FullName, Email, City, MemberTier)
VALUES
    (101, 'Alice Johnson',  'alice@example.com',  'London',    'Gold'),
    (102, 'Bob Smith',      'bob@example.com',    'Manchester','Silver'),
    (103, 'Carol Williams', 'carol@example.com',  'Edinburgh', 'Bronze'),
    (104, 'David Brown',    'david@example.com',  'Belfast',   'Gold'),
    (105, 'Eve Davis',      'eve@example.com',    'Cardiff',   'Silver');

SELECT 'Initial data:' AS Step;
SELECT * FROM [dbo].[Customers];

-- ============================================================================
-- STEP 2: Record the "before" timestamp (first run - SCD table will be created)
-- ============================================================================
PRINT '=== STEP 2: Recording the BEFORE timestamp ===';

DECLARE @before_time_1 VARCHAR(26) = CONVERT(VARCHAR(26), GETUTCDATE(), 127);
PRINT 'Before timestamp (Run 1): ' + @before_time_1;

-- Wait to ensure time-travel can distinguish the two points
WAITFOR DELAY '00:01:00';  -- Wait 1 minute

-- ============================================================================
-- STEP 3: Make changes to the table (simulating real-world modifications)
-- ============================================================================
PRINT '=== STEP 3: Making changes (Run 1) ===';

-- UPDATE: Bob moved to Liverpool and got upgraded to Gold
UPDATE [dbo].[Customers]
SET City = 'Liverpool', MemberTier = 'Gold'
WHERE CustomerID = 102;
PRINT 'Updated: Bob Smith - moved to Liverpool, upgraded to Gold';

-- DELETE: Eve's account was closed
DELETE FROM [dbo].[Customers]
WHERE CustomerID = 105;
PRINT 'Deleted: Eve Davis (CustomerID = 105)';

-- INSERT: New customer Frank
INSERT INTO [dbo].[Customers] (CustomerID, FullName, Email, City, MemberTier)
VALUES (106, 'Frank Miller', 'frank@example.com', 'Bristol', 'Bronze');
PRINT 'Inserted: Frank Miller (CustomerID = 106)';

SELECT 'Data after Run 1 changes:' AS Step;
SELECT * FROM [dbo].[Customers];

-- ============================================================================
-- STEP 4: Record the "after" timestamp and run FindChanges_SCD (first run)
-- ============================================================================
PRINT '=== STEP 4: Recording AFTER timestamp and running FindChanges_SCD (Run 1) ===';

DECLARE @after_time_1 VARCHAR(26) = CONVERT(VARCHAR(26), GETUTCDATE(), 127);
PRINT 'After timestamp (Run 1): ' + @after_time_1;

-- Execute the SCD procedure
-- This will CREATE the SCD table and seed it, then apply the detected changes
EXEC [dbo].[FindChanges_SCD]
    @tablename  = '[dbo].[Customers]',
    @keycolumn  = 'CustomerID',
    @startdt    = @before_time_1,
    @enddt      = @after_time_1;

-- ============================================================================
-- STEP 5: Inspect the SCD table after first run
-- ============================================================================
PRINT '=== STEP 5: Inspecting [dbo].[Customers_SCD] after Run 1 ===';

SELECT 'All SCD records:' AS Step;
SELECT * FROM [dbo].[Customers_SCD] ORDER BY CustomerID, _SCD_StartDate;

SELECT 'Current active records only:' AS Step;
SELECT * FROM [dbo].[Customers_SCD]
WHERE _SCD_EndDate IS NULL AND _SCD_DeletedFlag = 0
ORDER BY CustomerID;

-- ============================================================================
-- EXPECTED SCD TABLE STATE AFTER RUN 1:
-- ============================================================================
-- | CustomerID | FullName       | City       | MemberTier | _SCD_StartDate     | _SCD_EndDate       | _SCD_DeletedFlag | _SCD_LastUpdated   |
-- |------------|----------------|------------|------------|--------------------|--------------------|------------------|--------------------|
-- | 101        | Alice Johnson  | London     | Gold       | <before_time_1>    | NULL               | 0                | <before_time_1>    |  ← unchanged
-- | 102        | Bob Smith      | Manchester | Silver     | <before_time_1>    | <after_time_1>     | 0                | <after_time_1>     |  ← closed (updated)
-- | 102        | Bob Smith      | Liverpool  | Gold       | <after_time_1>     | NULL               | 0                | <after_time_1>     |  ← new version
-- | 103        | Carol Williams | Edinburgh  | Bronze     | <before_time_1>    | NULL               | 0                | <before_time_1>    |  ← unchanged
-- | 104        | David Brown    | Belfast    | Gold       | <before_time_1>    | NULL               | 0                | <before_time_1>    |  ← unchanged
-- | 105        | Eve Davis      | Cardiff    | Silver     | <before_time_1>    | <after_time_1>     | 1                | <after_time_1>     |  ← deleted
-- | 106        | Frank Miller   | Bristol    | Bronze     | <after_time_1>     | NULL               | 0                | <after_time_1>     |  ← new
-- ============================================================================

-- ============================================================================
-- STEP 6: Make more changes and run a SECOND incremental load
-- ============================================================================
PRINT '=== STEP 6: Preparing for Run 2 ===';

DECLARE @before_time_2 VARCHAR(26) = CONVERT(VARCHAR(26), GETUTCDATE(), 127);
PRINT 'Before timestamp (Run 2): ' + @before_time_2;

WAITFOR DELAY '00:01:00';  -- Wait 1 minute

PRINT 'Making changes (Run 2)...';

-- UPDATE: Alice moved to Birmingham
UPDATE [dbo].[Customers]
SET City = 'Birmingham'
WHERE CustomerID = 101;
PRINT 'Updated: Alice Johnson - moved to Birmingham';

-- UPDATE: Frank upgraded to Silver
UPDATE [dbo].[Customers]
SET MemberTier = 'Silver'
WHERE CustomerID = 106;
PRINT 'Updated: Frank Miller - upgraded to Silver';

-- INSERT: New customer Grace
INSERT INTO [dbo].[Customers] (CustomerID, FullName, Email, City, MemberTier)
VALUES (107, 'Grace Lee', 'grace@example.com', 'Glasgow', 'Gold');
PRINT 'Inserted: Grace Lee (CustomerID = 107)';

SELECT 'Data after Run 2 changes:' AS Step;
SELECT * FROM [dbo].[Customers];

-- Record after timestamp for Run 2
DECLARE @after_time_2 VARCHAR(26) = CONVERT(VARCHAR(26), GETUTCDATE(), 127);
PRINT 'After timestamp (Run 2): ' + @after_time_2;

-- ============================================================================
-- STEP 7: Execute FindChanges_SCD again (incremental run)
-- ============================================================================
PRINT '=== STEP 7: Running FindChanges_SCD (Run 2 - incremental) ===';

EXEC [dbo].[FindChanges_SCD]
    @tablename  = '[dbo].[Customers]',
    @keycolumn  = 'CustomerID',
    @startdt    = @before_time_2,
    @enddt      = @after_time_2;

-- ============================================================================
-- STEP 8: Inspect the SCD table after second run
-- ============================================================================
PRINT '=== STEP 8: Inspecting [dbo].[Customers_SCD] after Run 2 ===';

SELECT 'Full SCD history (all versions):' AS Step;
SELECT * FROM [dbo].[Customers_SCD] ORDER BY CustomerID, _SCD_StartDate;

SELECT 'Current active records only:' AS Step;
SELECT * FROM [dbo].[Customers_SCD]
WHERE _SCD_EndDate IS NULL AND _SCD_DeletedFlag = 0
ORDER BY CustomerID;

-- ============================================================================
-- STEP 9: Demonstrate SCD query patterns
-- ============================================================================
PRINT '=== STEP 9: SCD Query Patterns ===';

-- Pattern 1: Get the full history for a specific customer
SELECT 'History for Bob Smith (CustomerID = 102):' AS Step;
SELECT CustomerID, FullName, City, MemberTier,
       _SCD_StartDate, _SCD_EndDate, _SCD_DeletedFlag
FROM [dbo].[Customers_SCD]
WHERE CustomerID = 102
ORDER BY _SCD_StartDate;

-- Pattern 2: Get the state of all records at a specific point in time
-- (point-in-time reconstruction from the SCD table)
SELECT 'State of all records as of Run 1 end time:' AS Step;
SELECT CustomerID, FullName, City, MemberTier
FROM [dbo].[Customers_SCD]
WHERE _SCD_StartDate <= @after_time_1
  AND (_SCD_EndDate IS NULL OR _SCD_EndDate > @after_time_1)
ORDER BY CustomerID;

-- Pattern 3: Find all records that were ever deleted
SELECT 'All records that were deleted:' AS Step;
SELECT CustomerID, FullName, City, MemberTier,
       _SCD_StartDate, _SCD_EndDate
FROM [dbo].[Customers_SCD]
WHERE _SCD_DeletedFlag = 1;

-- Pattern 4: Find records that have been updated (have multiple versions)
SELECT 'Records with multiple versions (updated at least once):' AS Step;
SELECT CustomerID, COUNT(*) AS VersionCount
FROM [dbo].[Customers_SCD]
GROUP BY CustomerID
HAVING COUNT(*) > 1
ORDER BY CustomerID;

-- Pattern 5: Get the latest version of every record (including deleted)
SELECT 'Latest version of every record:' AS Step;
SELECT c.*
FROM [dbo].[Customers_SCD] c
INNER JOIN (
    SELECT CustomerID, MAX(_SCD_StartDate) AS MaxStart
    FROM [dbo].[Customers_SCD]
    GROUP BY CustomerID
) latest ON c.CustomerID = latest.CustomerID
        AND c._SCD_StartDate = latest.MaxStart
ORDER BY c.CustomerID;

-- ============================================================================
-- STEP 10: Clean up test data (optional)
-- ============================================================================
-- Uncomment the lines below to remove all test objects when done
-- DROP TABLE [dbo].[Customers];
-- DROP TABLE [dbo].[Customers_SCD];

PRINT '=== Demo complete! ===';
PRINT '';
PRINT 'Summary:';
PRINT '  - Run 1 created the SCD table, seeded it, and applied INSERT/UPDATE/DELETE';
PRINT '  - Run 2 demonstrated incremental SCD updates on an existing SCD table';
PRINT '  - Query patterns showed how to interrogate the SCD history';
