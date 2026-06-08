-- ============================================================================
-- TEST SCRIPT: [dbo].[findchanges_safe]
-- Description: End-to-end demo showing how to use the findchanges_safe
--              procedure to safely query a table at a specific point in time
--              using Fabric DW time-travel, with built-in validation and
--              timestamp clamping.
--
-- Prerequisites:
--   - Microsoft Fabric Data Warehouse or SQL Analytics Endpoint
--   - The [dbo].[findchanges_safe] procedure has been created
--     (see findchanges_safe.sql)
--   - Time-travel retention is available (default in Fabric)
--
-- IMPORTANT: This script uses WAITFOR DELAY to allow time between operations
--            so that time-travel can distinguish between table states. In
--            production, you would use known timestamps from your pipeline.
--
-- What findchanges_safe does:
--   - Accepts a table name and a UTC point-in-time timestamp
--   - Validates the table exists in the warehouse
--   - Clamps the timestamp: if before table creation → uses create_date;
--     if in the future → uses current UTC time
--   - Returns the full table state at that point in time via time-travel
-- ============================================================================

-- ============================================================================
-- STEP 1: Create a test table with sample data
-- ============================================================================
PRINT '=== STEP 1: Creating test table [dbo].[Orders] ===';

IF OBJECT_ID(N'[dbo].[Orders]', N'U') IS NOT NULL
    DROP TABLE [dbo].[Orders];

CREATE TABLE [dbo].[Orders]
(
    OrderID     INT           NOT NULL,
    CustomerID  INT           NOT NULL,
    ProductName VARCHAR(100)  NOT NULL,
    Quantity    INT           NOT NULL,
    OrderDate   DATE          NOT NULL,
    TotalAmount DECIMAL(10,2) NOT NULL
);

-- Insert initial data
INSERT INTO [dbo].[Orders] (OrderID, CustomerID, ProductName, Quantity, OrderDate, TotalAmount)
VALUES
    (1001, 10, 'Laptop Pro',     1, '2026-06-01', 1299.99),
    (1002, 20, 'Wireless Mouse', 3, '2026-06-02',   89.97),
    (1003, 30, 'USB Hub',        2, '2026-06-03',   49.98),
    (1004, 10, 'Monitor 27"',    1, '2026-06-04',  499.99),
    (1005, 40, 'Keyboard',       1, '2026-06-05',   79.99);

SELECT 'Initial data (5 orders):' AS Step;
SELECT * FROM [dbo].[Orders] ORDER BY OrderID;

-- ============================================================================
-- STEP 2: Record the "before" timestamp and wait
-- ============================================================================
PRINT '=== STEP 2: Recording the BEFORE timestamp ===';

DECLARE @time_before_changes DATETIME2(3) = CAST(SYSUTCDATETIME() AS DATETIME2(3));
PRINT 'Timestamp before changes: ' + CONVERT(VARCHAR(33), @time_before_changes, 126);

-- Wait to ensure time-travel can distinguish the states
WAITFOR DELAY '00:01:00';  -- Wait 1 minute

-- ============================================================================
-- STEP 3: Make changes to the table
-- ============================================================================
PRINT '=== STEP 3: Making changes to the Orders table ===';

-- UPDATE: Change quantity and amount for order 1002
UPDATE [dbo].[Orders]
SET Quantity = 5, TotalAmount = 149.95
WHERE OrderID = 1002;
PRINT 'Updated: Order 1002 quantity changed from 3 to 5';

-- DELETE: Remove order 1003
DELETE FROM [dbo].[Orders]
WHERE OrderID = 1003;
PRINT 'Deleted: Order 1003 (USB Hub)';

-- INSERT: Add new orders
INSERT INTO [dbo].[Orders] (OrderID, CustomerID, ProductName, Quantity, OrderDate, TotalAmount)
VALUES
    (1006, 50, 'Webcam HD', 1, '2026-06-06', 129.99),
    (1007, 20, 'Desk Lamp', 2, '2026-06-06',  59.98);
PRINT 'Inserted: Orders 1006 and 1007';

SELECT 'Data after changes (6 orders):' AS Step;
SELECT * FROM [dbo].[Orders] ORDER BY OrderID;

-- ============================================================================
-- STEP 4: Use findchanges_safe to query the table BEFORE the changes
-- ============================================================================
PRINT '=== STEP 4: Querying table state BEFORE changes using findchanges_safe ===';
PRINT 'Requesting state at: ' + CONVERT(VARCHAR(33), @time_before_changes, 126);

EXEC [dbo].[findchanges_safe]
    @TableName   = 'dbo.Orders',
    @PointInTime = @time_before_changes;

-- EXPECTED: Returns the original 5 rows (before update/delete/insert)
-- | OrderID | CustomerID | ProductName    | Quantity | OrderDate  | TotalAmount |
-- |---------|------------|----------------|----------|------------|-------------|
-- | 1001    | 10         | Laptop Pro     | 1        | 2026-06-01 | 1299.99     |
-- | 1002    | 20         | Wireless Mouse | 3        | 2026-06-02 | 89.97       |  ← original qty
-- | 1003    | 30         | USB Hub        | 2        | 2026-06-03 | 49.98       |  ← still exists
-- | 1004    | 10         | Monitor 27"    | 1        | 2026-06-04 | 499.99      |
-- | 1005    | 40         | Keyboard       | 1        | 2026-06-05 | 79.99       |

-- ============================================================================
-- STEP 5: Query the table at current time (after changes)
-- ============================================================================
PRINT '=== STEP 5: Querying table state NOW (after changes) ===';

DECLARE @time_now DATETIME2(3) = CAST(SYSUTCDATETIME() AS DATETIME2(3));
PRINT 'Requesting state at: ' + CONVERT(VARCHAR(33), @time_now, 126);

EXEC [dbo].[findchanges_safe]
    @TableName   = 'dbo.Orders',
    @PointInTime = @time_now;

-- EXPECTED: Returns the current 6 rows (with changes applied)

-- ============================================================================
-- STEP 6: Test timestamp clamping - future timestamp
-- ============================================================================
PRINT '=== STEP 6: Testing future timestamp clamping ===';
PRINT 'Requesting a time far in the future - should clamp to current UTC time';

DECLARE @future_time DATETIME2(3) = '2030-12-31T23:59:59.999';

EXEC [dbo].[findchanges_safe]
    @TableName   = 'dbo.Orders',
    @PointInTime = @future_time;

-- EXPECTED: Returns current state (clamped to now) - same as STEP 5

-- ============================================================================
-- STEP 7: Test timestamp clamping - very old timestamp (before table creation)
-- ============================================================================
PRINT '=== STEP 7: Testing past timestamp clamping (before table existed) ===';
PRINT 'Requesting a time before the table was created - should clamp to table create_date';

DECLARE @old_time DATETIME2(3) = '2020-01-01T00:00:00.000';

EXEC [dbo].[findchanges_safe]
    @TableName   = 'dbo.Orders',
    @PointInTime = @old_time;

-- EXPECTED: Returns the earliest available state (clamped to table creation time)

-- ============================================================================
-- STEP 8: Test table name variations (one-part and two-part names)
-- ============================================================================
PRINT '=== STEP 8: Testing different table name formats ===';

-- One-part name (defaults to dbo schema)
PRINT 'Testing one-part name: Orders';
EXEC [dbo].[findchanges_safe]
    @TableName   = 'Orders',
    @PointInTime = @time_before_changes;

-- Two-part name with schema
PRINT 'Testing two-part name: dbo.Orders';
EXEC [dbo].[findchanges_safe]
    @TableName   = 'dbo.Orders',
    @PointInTime = @time_before_changes;

-- ============================================================================
-- STEP 9: Test error handling - invalid table name
-- ============================================================================
PRINT '=== STEP 9: Testing error handling ===';

-- Test 1: Non-existent table (should throw error 50003)
PRINT 'Test: Non-existent table...';
BEGIN TRY
    EXEC [dbo].[findchanges_safe]
        @TableName   = 'dbo.NonExistentTable',
        @PointInTime = @time_now;
END TRY
BEGIN CATCH
    PRINT 'Expected error caught: ' + ERROR_MESSAGE();
    PRINT 'Error number: ' + CAST(ERROR_NUMBER() AS VARCHAR(10));
END CATCH;

-- Test 2: NULL table name (should throw error 50000)
PRINT 'Test: NULL table name...';
BEGIN TRY
    EXEC [dbo].[findchanges_safe]
        @TableName   = NULL,
        @PointInTime = @time_now;
END TRY
BEGIN CATCH
    PRINT 'Expected error caught: ' + ERROR_MESSAGE();
    PRINT 'Error number: ' + CAST(ERROR_NUMBER() AS VARCHAR(10));
END CATCH;

-- Test 3: Three-part name (should throw error 50001)
PRINT 'Test: Three-part name (not allowed)...';
BEGIN TRY
    EXEC [dbo].[findchanges_safe]
        @TableName   = 'mydb.dbo.Orders',
        @PointInTime = @time_now;
END TRY
BEGIN CATCH
    PRINT 'Expected error caught: ' + ERROR_MESSAGE();
    PRINT 'Error number: ' + CAST(ERROR_NUMBER() AS VARCHAR(10));
END CATCH;

-- ============================================================================
-- STEP 10: Practical use case - compare before/after visually
-- ============================================================================
PRINT '=== STEP 10: Practical use case - visual comparison ===';
PRINT 'Compare the table at two different points in time:';
PRINT '';
PRINT '--- State BEFORE changes ---';

EXEC [dbo].[findchanges_safe]
    @TableName   = 'Orders',
    @PointInTime = @time_before_changes;

PRINT '';
PRINT '--- State AFTER changes (current) ---';

EXEC [dbo].[findchanges_safe]
    @TableName   = 'Orders',
    @PointInTime = @time_now;

-- ============================================================================
-- STEP 11: Clean up test data (optional)
-- ============================================================================
-- Uncomment the line below to remove the test table when done
-- DROP TABLE [dbo].[Orders];

PRINT '';
PRINT '=== Demo complete! ===';
PRINT '';
PRINT 'Summary of findchanges_safe features demonstrated:';
PRINT '  - Query table state at any point in time (time-travel)';
PRINT '  - Automatic timestamp clamping (future → now, past → table creation)';
PRINT '  - Flexible table name input (one-part or two-part)';
PRINT '  - Robust error handling (invalid names, non-existent tables)';
PRINT '  - Safe against SQL injection (uses QUOTENAME + PARSENAME validation)';
