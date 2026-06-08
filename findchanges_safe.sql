CREATE OR ALTER PROCEDURE dbo.findchanges_safe
(
    @TableName   NVARCHAR(256),   -- accepts: table or schema.table
    @PointInTime DATETIME2(3)     -- must be UTC
)
AS
BEGIN
    -------------------------------------------------------------------------
    -- Fabric DW time travel notes from public docs:
    -- - FOR TIMESTAMP AS OF is UTC only
    -- - format should be yyyy-MM-ddTHH:mm:ss[.fff]
    -- - value must be deterministic in OPTION clause, so dynamic SQL is used
    -------------------------------------------------------------------------

    DECLARE 
        @SchemaName       SYSNAME,
        @ObjectName       SYSNAME,
        @SchemaQualified  NVARCHAR(517),
        @TableCreateDate  DATETIME2(3),
        @NowUtc           DATETIME2(3),
        @EffectiveTime    DATETIME2(3),
        @PointInTimeText  VARCHAR(33),
        @Sql              NVARCHAR(MAX);

    -------------------------------------------------------------------------
    -- Validate and normalise table name
    -- Only allow:
    --   table_name
    --   schema_name.table_name
    -------------------------------------------------------------------------
    IF @TableName IS NULL OR LTRIM(RTRIM(@TableName)) = N''
    BEGIN
        THROW 50000, 'Table name is required.', 1;
    END;

    -- Reject 3-part / 4-part names to keep this Fabric Warehouse scoped
    IF PARSENAME(@TableName, 3) IS NOT NULL
       OR PARSENAME(@TableName, 4) IS NOT NULL
    BEGIN
        THROW 50001, 'Use only a one-part or two-part table name: table or schema.table.', 1;
    END;

    SET @ObjectName = PARSENAME(@TableName, 1);
    SET @SchemaName = PARSENAME(@TableName, 2);

    IF @ObjectName IS NULL
    BEGIN
        THROW 50002, 'Invalid table name.', 1;
    END;

    IF @SchemaName IS NULL
    BEGIN
        SET @SchemaName = N'dbo';
    END;

    -------------------------------------------------------------------------
    -- Validate the table exists and get its create_date
    -------------------------------------------------------------------------
    SELECT
        @TableCreateDate = CAST(t.create_date AS DATETIME2(3))
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s
        ON t.schema_id = s.schema_id
    WHERE s.name = @SchemaName
      AND t.name = @ObjectName;

    IF @TableCreateDate IS NULL
    BEGIN
        THROW 50003, 'The specified table does not exist in this warehouse.', 1;
    END;

    -------------------------------------------------------------------------
    -- Validate / clamp the requested timestamp
    -- 1) If earlier than table create_date, use create_date
    -- 2) If in the future, use current UTC time
    -------------------------------------------------------------------------
    SET @NowUtc = CAST(SYSUTCDATETIME() AS DATETIME2(3));
    SET @EffectiveTime = @PointInTime;

    IF @EffectiveTime < @TableCreateDate
    BEGIN
        SET @EffectiveTime = @TableCreateDate;
    END;

    IF @EffectiveTime > @NowUtc
    BEGIN
        SET @EffectiveTime = @NowUtc;
    END;

    -------------------------------------------------------------------------
    -- Convert to ISO 8601 style expected by FOR TIMESTAMP AS OF
    -------------------------------------------------------------------------
    SET @PointInTimeText = CONVERT(VARCHAR(33), @EffectiveTime, 126);

    -------------------------------------------------------------------------
    -- Build and execute Fabric DW time-travel SELECT
    -------------------------------------------------------------------------
    SET @SchemaQualified = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ObjectName);

    SET @Sql = N'
SELECT *
FROM ' + @SchemaQualified + N'
OPTION (FOR TIMESTAMP AS OF ''' + @PointInTimeText + N''');';

    EXEC sp_executesql @Sql;
END;
GO