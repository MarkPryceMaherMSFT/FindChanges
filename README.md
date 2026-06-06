# FindChanges – Detect Table Changes in Microsoft Fabric

A stored procedure for **Microsoft Fabric Data Warehouse** and **Fabric SQL Analytics Endpoint** that identifies row-level changes (inserts, updates, and deletes) between two points in time using Fabric's built-in time-travel capability (`FOR TIMESTAMP AS OF`).

## How It Works

1. Takes a snapshot of the target table at the **start** timestamp.
2. Takes a snapshot of the same table at the **end** timestamp.
3. Uses `EXCEPT` set operations to compare the two snapshots:
   - Rows in the start snapshot but **not** in the end snapshot → **Removed**
   - Rows in the end snapshot but **not** in the start snapshot → **Inserted/Updated**
4. Returns a unified result set with an `action` column indicating the type of change.

> **Note:** Updated rows will appear twice — once as `Removed` (the old values) and once as `Inserted/Updated` (the new values) — because the comparison is performed on the full row.

## Prerequisites

- A Microsoft Fabric Data Warehouse or SQL Analytics Endpoint.
- Time-travel must be available for the target table (this is enabled by default in Fabric).
- The timestamps provided must fall within the retention period.

## Installation

Run the contents of [`findchanges.sql`](findchanges.sql) in your Fabric SQL editor to create the stored procedure:

```sql
-- Execute the script in your Fabric DW / SQL Analytics Endpoint
-- to create the [dbo].[FindChanges] procedure.
```

## Usage

```sql
-- Declare the time window and target table
DECLARE @startdt VARCHAR(26);
DECLARE @enddt VARCHAR(26);
DECLARE @tablename VARCHAR(50);

SET @startdt   = '2026-06-06T14:45:35.28';
SET @enddt     = '2026-06-06T15:05:55.28';
SET @tablename = '[dbo].[foo2]';

-- Execute the procedure
EXEC [dbo].[FindChanges] @tablename, @startdt, @enddt;
```

### Example Output

| action           | id | name   | value |
|------------------|----|--------|-------|
| Removed          | 3  | itemC  | 100   |
| Inserted/Updated | 3  | itemC  | 150   |
| Inserted/Updated | 7  | itemG  | 42    |

In this example:
- Row `id=3` was **updated** (value changed from 100 → 150).
- Row `id=7` was **inserted** (new row that didn't exist at the start time).

## Parameters

| Parameter    | Type          | Description                                          |
|--------------|---------------|------------------------------------------------------|
| `@tablename` | `VARCHAR(50)` | Schema-qualified table name, e.g. `[dbo].[foo2]`    |
| `@startdt`   | `VARCHAR(26)` | Start timestamp (ISO 8601), the "before" snapshot    |
| `@enddt`     | `VARCHAR(26)` | End timestamp (ISO 8601), the "after" snapshot       |

## Limitations

- The procedure creates temporary staging tables (`Orginal_tbl`, `new_tbl`) in the `dbo` schema. Concurrent executions may conflict.
- Very large tables will consume storage for the two snapshot copies.
- The `EXCEPT` comparison is across all columns; if a row's non-key columns haven't changed, it won't appear in the results.

## License

This project is provided as-is for use within Microsoft Fabric environments.
