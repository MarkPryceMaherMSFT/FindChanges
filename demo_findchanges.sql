-- ============================================================================
-- TEST SCRIPT: [dbo].[FindChanges]
-- Description: End-to-end demo showing how to create a test table, make
--              changes, and use FindChanges to detect them via time-travel.
--
-- Prerequisites:
--   - Microsoft Fabric Data Warehouse or SQL Analytics Endpoint
--   - The [dbo].[FindChanges] procedure has been created (see findchanges.sql)
--   - Time-travel retention is available (default in Fabric)
--
-- IMPORTANT: This script uses WAITFOR DELAY to allow time between operations
--            so that time-travel can distinguish the snapshots. In production,
--            you would use known timestamps from your ETL pipeline or logs.
-- ============================================================================

-- ============================================================================
-- STEP 1: Create a test table with sample data
-- ============================================================================
PRINT '=== STEP 1: Creating test table [dbo].[TestProducts] ===';

IF OBJECT_ID(N'[dbo].[TestProducts]', N'U') IS NOT NULL
    DROP TABLE [dbo].[TestProducts];

CREATE TABLE [dbo].[TestProducts]
(
    ProductID   INT          NOT NULL,
    ProductName VARCHAR(100) NOT NULL,
    Category    VARCHAR(50)  NOT NULL,
    Price       DECIMAL(10,2) NOT NULL
);

-- Insert initial data
INSERT INTO [dbo].[TestProducts] (ProductID, ProductName, Category, Price)
VALUES
    (1, 'Widget A',  'Hardware',  19.99),
    (2, 'Widget B',  'Hardware',  29.99),
    (3, 'Gadget C',  'Electronics', 49.99),
    (4, 'Gadget D',  'Electronics', 99.99),
    (5, 'Service E', 'Software',  149.99);

SELECT 'Initial data:' AS Step;
SELECT * FROM [dbo].[TestProducts];

-- ============================================================================
-- STEP 2: Record the "before" timestamp
-- ============================================================================
PRINT '=== STEP 2: Recording the BEFORE timestamp ===';

-- Capture the current time as our start point
-- NOTE: In a real scenario you would know the timestamp from your last ETL run
DECLARE @before_time VARCHAR(26) = CONVERT(VARCHAR(26), GETUTCDATE(), 127);
PRINT 'Before timestamp: ' + @before_time;

-- Wait to ensure time-travel can distinguish the two points
-- (In production, this gap happens naturally between ETL runs)
WAITFOR DELAY '00:01:00';  -- Wait 1 minute

-- ============================================================================
-- STEP 3: Make changes to the table (simulating real-world modifications)
-- ============================================================================
PRINT '=== STEP 3: Making changes to the table ===';

-- UPDATE: Change the price of Widget B
UPDATE [dbo].[TestProducts]
SET Price = 34.99
WHERE ProductID = 2;
PRINT 'Updated: Widget B price changed from 29.99 to 34.99';

-- DELETE: Remove Service E
DELETE FROM [dbo].[TestProducts]
WHERE ProductID = 5;
PRINT 'Deleted: Service E (ProductID = 5)';

-- INSERT: Add a new product
INSERT INTO [dbo].[TestProducts] (ProductID, ProductName, Category, Price)
VALUES (6, 'Gizmo F', 'Hardware', 12.99);
PRINT 'Inserted: Gizmo F (ProductID = 6)';

SELECT 'Data after changes:' AS Step;
SELECT * FROM [dbo].[TestProducts];

-- ============================================================================
-- STEP 4: Record the "after" timestamp
-- ============================================================================
PRINT '=== STEP 4: Recording the AFTER timestamp ===';

DECLARE @after_time VARCHAR(26) = CONVERT(VARCHAR(26), GETUTCDATE(), 127);
PRINT 'After timestamp: ' + @after_time;

-- ============================================================================
-- STEP 5: Execute FindChanges to detect the differences
-- ============================================================================
PRINT '=== STEP 5: Executing [dbo].[FindChanges] ===';
PRINT 'Comparing table state between:';
PRINT '  Start: ' + @before_time;
PRINT '  End:   ' + @after_time;

EXEC [dbo].[FindChanges] '[dbo].[TestProducts]', @before_time, @after_time;

-- ============================================================================
-- EXPECTED RESULTS:
-- ============================================================================
-- The output should show:
--
-- | action           | ProductID | ProductName | Category    | Price  |
-- |------------------|-----------|-------------|-------------|--------|
-- | Removed          | 2         | Widget B    | Hardware    | 29.99  |  ← old price
-- | Removed          | 5         | Service E   | Software    | 149.99 |  ← deleted row
-- | Inserted/Updated | 2         | Widget B    | Hardware    | 34.99  |  ← new price
-- | Inserted/Updated | 6         | Gizmo F     | Hardware    | 12.99  |  ← new row
--
-- Interpretation:
--   - ProductID 2 appears as both Removed and Inserted/Updated → it was UPDATED
--   - ProductID 5 appears only as Removed → it was DELETED
--   - ProductID 6 appears only as Inserted/Updated → it was INSERTED
-- ============================================================================

-- ============================================================================
-- STEP 6: Clean up test data (optional)
-- ============================================================================
-- Uncomment the line below to remove the test table when done
-- DROP TABLE [dbo].[TestProducts];

PRINT '=== Demo complete! ===';
