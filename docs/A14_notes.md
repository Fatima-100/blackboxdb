# A14 notes: Stretch topics — Concurrency, Partitioning, Temporal Tables (Member A)

## Files
- [`concurrency_demo.sql`](../concurrency_demo.sql) — two-window SSMS script demonstrating:
  - `(a)` Lost update prevented by `ROWVERSION` (`@@ROWCOUNT = 0`)
  - `(b)` Dirty read (`READ UNCOMMITTED` vs `READ COMMITTED`)
  - `(c)` Non-repeatable read vs `REPEATABLE READ`
  - `(d)` Deadlock (`Msg 1205`) and fix (consistent lock order + `TRY...CATCH` retry)
  - `(e)` `SNAPSHOT` isolation (`ALLOW_SNAPSHOT_ISOLATION ON`)
- [`stretch_partition_temporal.sql`](../stretch_partition_temporal.sql) —
  - Date partitioning on `Incident_Part` (`pf_year`, `ps_year`, `$PARTITION.pf_year`, partition elimination)
  - System-versioned temporal table on `Aircraft` (`valid_from`, `valid_to`, `dbo.Aircraft_History`, `AS OF`, `BETWEEN`, `ALL`)

## Isolation Levels Reference
| Isolation Level | Dirty Read | Non-Repeatable Read | Phantom Read |
|---|---|---|---|
| `READ UNCOMMITTED` | Allowed | Allowed | Allowed |
| `READ COMMITTED` *(default)* | Prevented | Allowed | Allowed |
| `REPEATABLE READ` | Prevented | Prevented | Allowed |
| `SERIALIZABLE` | Prevented | Prevented | Prevented |
| `SNAPSHOT` | Prevented | Prevented | Prevented *(row versioning in tempdb)* |

## Viva Prep
- **The 4 concurrency problems & what stops each:**
  1. *Lost update* → `ROWVERSION` (optimistic concurrency) or `REPEATABLE READ`+
  2. *Dirty read* → `READ COMMITTED` or `SNAPSHOT`
  3. *Non-repeatable read* → `REPEATABLE READ`, `SERIALIZABLE`, or `SNAPSHOT`
  4. *Phantom read* → `SERIALIZABLE` (range locks) or `SNAPSHOT`
- **What is a deadlock and how does SQL Server pick a victim?**  
  Two sessions hold locks the other needs and neither can proceed. SQL Server's lock monitor detects the cycle and rolls back the session with the **lowest rollback cost** (or `DEADLOCK_PRIORITY`), raising **error 1205**.
- **Why partition by date?**  
  Time-range queries only read the matching partitions (**partition elimination**), and old partitions can be archived or dropped (`SWITCH`) almost instantly without scanning the whole table.
- **What does the temporal history table (`Aircraft_History`) store?**  
  Every previous version of a row whenever an `UPDATE` or `DELETE` happens, stamped with `[valid_from, valid_to)` UTC timestamps managed automatically by SQL Server.
