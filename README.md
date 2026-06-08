# FindChanges – Detect Table Changes in Microsoft Fabric

Stored procedures for **Microsoft Fabric Data Warehouse** and **Fabric SQL Analytics Endpoint** that identify row-level changes (inserts, updates, and deletes) between two points in time using Fabric's built-in time-travel capability (`FOR TIMESTAMP AS OF`).

## Procedures

| Procedure | Description |
|-----------|-------------|
| [`FindChanges`](findchanges.sql) | Simple change detection – returns rows that differ between two timestamps |
| [`FindChanges_SCD`](findchanges_scd.sql) | Change detection with Type 2 SCD – classifies changes by business key and maintains a historical dimension table |
| [`findchanges_safe`](findchanges_safe.sql) | Safe point-in-time query – returns table state at a given timestamp with input validation and timestamp clamping |

---

## FindChanges (Simple)

### How It Works

1. Takes a snapshot of the target table at the **start** timestamp.
2. Takes a snapshot of the same table at the **end** timestamp.
3. Uses `EXCEPT` set operations to compare the two snapshots:
   - Rows in the start snapshot but **not** in the end snapshot → **Removed**
   - Rows in the end snapshot but **not** in the start snapshot → **Inserted/Updated**
4. Returns a unified result set with an `action` column indicating the type of change.

> **Note:** Updated rows will appear twice — once as `Removed` (the old values) and once as `Inserted/Updated` (the new values) — because the comparison is performed on the full row.

### Usage

```sql
DECLARE @startdt VARCHAR(26);
DECLARE @enddt VARCHAR(26);
DECLARE @tablename VARCHAR(50);

SET @startdt   = '2026-06-06T14:45:35.28';
SET @enddt     = '2026-06-06T15:05:55.28';
SET @tablename = '[dbo].[foo2]';

EXEC [dbo].[FindChanges] @tablename, @startdt, @enddt;
```

### Example Output

| action           | id | name   | value |
|------------------|----|--------|-------|
| Removed          | 3  | itemC  | 100   |
| Inserted/Updated | 3  | itemC  | 150   |
| Inserted/Updated | 7  | itemG  | 42    |

---

## findchanges_safe (Safe Point-in-Time Query)

### How It Works

1. Validates and normalises the table name (accepts one-part `Orders` or two-part `dbo.Orders`).
2. Verifies the table exists in the warehouse via `sys.tables`.
3. Clamps the requested timestamp:
   - If **before** the table's `create_date` → uses the table creation time
   - If **in the future** → uses current UTC time
4. Executes a time-travel query (`FOR TIMESTAMP AS OF`) and returns the full table state at that point in time.

### Features

- **Input validation** – rejects NULL, empty, or three-part+ names with clear error messages
- **SQL injection protection** – uses `PARSENAME` for parsing and `QUOTENAME` for output
- **Timestamp clamping** – never fails due to out-of-range timestamps
- **Strongly typed** – uses `DATETIME2(3)` for the timestamp parameter (UTC)

### Usage

```sql
-- Query table state at a specific point in time
DECLARE @pit DATETIME2(3) = '2026-06-06T14:45:35.280';

EXEC [dbo].[findchanges_safe]
    @TableName   = 'dbo.Orders',
    @PointInTime = @pit;
```

```sql
-- One-part table name (defaults to dbo schema)
EXEC [dbo].[findchanges_safe]
    @TableName   = 'Orders',
    @PointInTime = '2026-06-06T15:00:00.000';
```

```sql
-- Future timestamp is automatically clamped to current UTC time
EXEC [dbo].[findchanges_safe]
    @TableName   = 'dbo.Orders',
    @PointInTime = '2030-12-31T23:59:59.999';
```

### Error Handling

| Error | Condition |
|-------|-----------|
| 50000 | Table name is NULL or empty |
| 50001 | Three-part or four-part name provided (only one/two-part allowed) |
| 50002 | Table name could not be parsed |
| 50003 | Table does not exist in the warehouse |

---

## FindChanges_SCD (Type 2 Slowly Changing Dimension)

### How It Works

1. Snapshots the table at the start and end timestamps (same as `FindChanges`).
2. Uses the **business key** (`@keycolumn`) to classify each change:
   - **New** – key exists in end snapshot but not in start snapshot
   - **Updated** – key exists in both but one or more non-key columns differ
   - **Deleted** – key exists in start snapshot but not in end snapshot
3. Creates a Type 2 SCD table (`{source_table}_SCD`) if it doesn't already exist.
4. Applies changes to the SCD table:
   - **New rows** → inserted with `_SCD_StartDate = @enddt`
   - **Updated rows** → old active record is closed (`_SCD_EndDate = @enddt`), new version inserted
   - **Deleted rows** → active record is closed and `_SCD_DeletedFlag` set to `1`

### SCD Table Schema

The SCD table contains all source columns plus four metadata columns:

| Column | Type | Description |
|--------|------|-------------|
| `_SCD_StartDate` | `DATETIME2` | When this version of the row became active |
| `_SCD_EndDate` | `DATETIME2` | When this version was superseded (`NULL` = current active record) |
| `_SCD_DeletedFlag` | `BIT` | `1` if the source row was deleted |
| `_SCD_LastUpdated` | `DATETIME2` | Last time this SCD record was modified |

### Usage

```sql
DECLARE @startdt VARCHAR(26);
DECLARE @enddt VARCHAR(26);
DECLARE @tablename VARCHAR(50);
DECLARE @keycolumn VARCHAR(50);

SET @startdt    = '2026-06-06T14:45:35.28';
SET @enddt      = '2026-06-06T15:05:55.28';
SET @tablename  = '[dbo].[foo2]';
SET @keycolumn  = 'ProductID';

EXEC [dbo].[FindChanges_SCD] @tablename, @keycolumn, @startdt, @enddt;
```

### Example Output

The procedure returns a summary of detected changes:

| action  | ProductID | name   | value |
|---------|-----------|--------|-------|
| New     | 7         | itemG  | 42    |
| Updated | 3         | itemC  | 150   |
| Deleted | 5         | itemE  | 80    |

And the SCD table (`[dbo].[foo2_SCD]`) will contain the full history:

| ProductID | name  | value | _SCD_StartDate | _SCD_EndDate | _SCD_DeletedFlag | _SCD_LastUpdated |
|-----------|-------|-------|----------------|--------------|------------------|------------------|
| 3 | itemC | 100 | 2026-06-06 14:45:35 | 2026-06-06 15:05:55 | 0 | 2026-06-06 15:05:55 |
| 3 | itemC | 150 | 2026-06-06 15:05:55 | NULL | 0 | 2026-06-06 15:05:55 |
| 5 | itemE | 80  | 2026-06-06 14:45:35 | 2026-06-06 15:05:55 | 1 | 2026-06-06 15:05:55 |
| 7 | itemG | 42  | 2026-06-06 15:05:55 | NULL | 0 | 2026-06-06 15:05:55 |

### Querying the SCD Table

```sql
-- Get current active records only
SELECT * FROM [dbo].[foo2_SCD] WHERE _SCD_EndDate IS NULL AND _SCD_DeletedFlag = 0;

-- Get the state of a specific record at a point in time
SELECT * FROM [dbo].[foo2_SCD]
WHERE ProductID = 3
  AND _SCD_StartDate <= '2026-06-06T15:00:00'
  AND (_SCD_EndDate IS NULL OR _SCD_EndDate > '2026-06-06T15:00:00');

-- Get all deleted records
SELECT * FROM [dbo].[foo2_SCD] WHERE _SCD_DeletedFlag = 1;
```

---

## Parameters Reference

### FindChanges

| Parameter    | Type          | Description                                          |
|--------------|---------------|------------------------------------------------------|
| `@tablename` | `VARCHAR(50)` | Schema-qualified table name, e.g. `[dbo].[foo2]`    |
| `@startdt`   | `VARCHAR(26)` | Start timestamp (ISO 8601), the "before" snapshot    |
| `@enddt`     | `VARCHAR(26)` | End timestamp (ISO 8601), the "after" snapshot       |

### findchanges_safe

| Parameter      | Type            | Description                                          |
|----------------|-----------------|------------------------------------------------------|
| `@TableName`   | `NVARCHAR(256)` | Table name: `table` or `schema.table`                |
| `@PointInTime` | `DATETIME2(3)`  | UTC timestamp to query the table at                  |

### FindChanges_SCD

| Parameter    | Type          | Description                                          |
|--------------|---------------|------------------------------------------------------|
| `@tablename` | `VARCHAR(50)` | Schema-qualified table name, e.g. `[dbo].[foo2]`    |
| `@keycolumn` | `VARCHAR(50)` | Business key column name, e.g. `ProductID`           |
| `@startdt`   | `VARCHAR(26)` | Start timestamp (ISO 8601), the "before" snapshot    |
| `@enddt`     | `VARCHAR(26)` | End timestamp (ISO 8601), the "after" snapshot       |

---

## Prerequisites

- A Microsoft Fabric Data Warehouse or SQL Analytics Endpoint.
- Time-travel must be available for the target table (enabled by default in Fabric).
- The timestamps provided must fall within the retention period.
- For `FindChanges_SCD`: the business key column must uniquely identify rows.

## Installation

Run the SQL scripts in your Fabric SQL editor:

```sql
-- 1. Create the simple FindChanges procedure
--    Execute the contents of findchanges.sql

-- 2. Create the safe point-in-time query procedure
--    Execute the contents of findchanges_safe.sql

-- 3. Create the SCD version
--    Execute the contents of findchanges_scd.sql
```

## Demo Scripts

End-to-end test scripts are included to demonstrate each procedure:

| Script | Description |
|--------|-------------|
| [`demo_findchanges.sql`](demo_findchanges.sql) | Creates a test table, makes changes (insert/update/delete), and runs `FindChanges` to show detected differences |
| [`demo_findchanges_safe.sql`](demo_findchanges_safe.sql) | Tests `findchanges_safe` with timestamp clamping, name format variations, and error handling |
| [`demo_findchanges_scd.sql`](demo_findchanges_scd.sql) | Full SCD lifecycle: creates a test table, runs two incremental loads, and demonstrates query patterns for the SCD history table |

Run these scripts in your Fabric SQL editor to see the procedures in action. They include `WAITFOR DELAY` pauses to ensure time-travel can distinguish between the before/after snapshots.

## Limitations

- Staging tables are created in the `dbo` schema. Concurrent executions may conflict.
- Very large tables will consume storage for the snapshot copies.
- The `EXCEPT` comparison is across all columns; if no non-key columns changed, the row won't be detected as updated.
- The SCD table must have the same schema as the source table. If the source schema changes, the SCD table may need manual updates.

## License

This project is provided as-is for use within Microsoft Fabric environments.
