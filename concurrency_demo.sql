/* ============================================================================
   concurrency_demo.sql  -  A14: Transactions & Concurrency Demo (Member A)
   How to run: Open TWO query tabs in SSMS (Window A and Window B), both with
   blackboxdb selected. Run each marked step in order — do NOT press F5 on
   the whole file at once.

   Isolation Levels Summary (what each allows):
   +-----------------------+------------+---------------------+--------------+
   | Isolation Level       | Dirty Read | Non-Repeatable Read | Phantom Read |
   +-----------------------+------------+---------------------+--------------+
   | READ UNCOMMITTED      | Yes        | Yes                 | Yes          |
   | READ COMMITTED (def.) | No         | Yes                 | Yes          |
   | REPEATABLE READ       | No         | No                  | Yes          |
   | SERIALIZABLE          | No         | No                  | No           |
   | SNAPSHOT              | No         | No                  | No           |
   +-----------------------+------------+---------------------+--------------+
   ============================================================================ */

/* ============================================================================
   (a) LOST UPDATE stopped by ROWVERSION
   Expected: Window A succeeds (1 row updated). Window B gets 0 rows updated
   and detects the conflict instead of silently overwriting Window A's change.
   ============================================================================ */
-- --- WINDOW A (step 1) ---
USE blackboxdb;
DECLARE @verA BINARY(8), @origLocA VARCHAR(255);
SELECT @verA = row_ver, @origLocA = location FROM dbo.Incident WHERE incident_id = 1;

-- --- WINDOW B (step 2: reads the SAME row_ver before Window A commits) ---
USE blackboxdb;
DECLARE @verB BINARY(8);
SELECT @verB = row_ver FROM dbo.Incident WHERE incident_id = 1;

-- --- WINDOW A (step 3: updates first -> SUCCEEDS, @@ROWCOUNT = 1) ---
UPDATE dbo.Incident
   SET location = 'Updated by Window A'
 WHERE incident_id = 1 AND row_ver = @verA;
SELECT @@ROWCOUNT AS window_a_rows;   -- Expected: 1

-- --- WINDOW B (step 4: tries to update with stale @verB -> BLOCKED, @@ROWCOUNT = 0) ---
UPDATE dbo.Incident
   SET location = 'Overwritten by Window B'
 WHERE incident_id = 1 AND row_ver = @verB;
SELECT @@ROWCOUNT AS window_b_rows;   -- Expected: 0 -> App shows "Record changed by another user"

-- --- CLEANUP (Window A: restore original location) ---
UPDATE dbo.Incident SET location = @origLocA WHERE incident_id = 1;
GO


/* ============================================================================
   (b) DIRTY READ: READ UNCOMMITTED vs READ COMMITTED
   Expected:
     - Under READ UNCOMMITTED, Window B sees 'DIRTY UNCOMMITTED TEST' even
       though Window A never committed (and later rolls back).
     - Under READ COMMITTED (default), Window B WAITS until Window A rolls
       back, and then sees the real committed location.
   ============================================================================ */
-- --- WINDOW A (step 1: start transaction and update WITHOUT committing) ---
USE blackboxdb;
BEGIN TRAN;
UPDATE dbo.Incident SET location = 'DIRTY UNCOMMITTED TEST' WHERE incident_id = 1;
-- Leave this transaction open!

-- --- WINDOW B (step 2: dirty read!) ---
USE blackboxdb;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT incident_id, location FROM dbo.Incident WHERE incident_id = 1;
-- Expected: shows 'DIRTY UNCOMMITTED TEST' (dirty read!)

-- --- WINDOW B (step 3: switch to READ COMMITTED -> will WAIT for Window A) ---
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT incident_id, location FROM dbo.Incident WHERE incident_id = 1;
-- Expected: blocks until Window A runs ROLLBACK below, then shows clean value.

-- --- WINDOW A (step 4: roll back) ---
ROLLBACK;
GO


/* ============================================================================
   (c) NON-REPEATABLE READ vs REPEATABLE READ
   Expected:
     - Under READ COMMITTED, Window B reads two different values inside the
       same transaction because Window A commits an update in between.
     - Under REPEATABLE READ, Window B holds a shared lock on the row so
       Window A's UPDATE waits until Window B commits.
   ============================================================================ */
-- --- Part 1: Non-repeatable read under READ COMMITTED ---
-- WINDOW B (step 1):
USE blackboxdb;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN TRAN;
SELECT incident_id, injuries FROM dbo.Incident WHERE incident_id = 2;  -- 1st read

-- WINDOW A (step 2: update & commit immediately while Window B is still in tran):
USE blackboxdb;
DECLARE @origInj INT = (SELECT injuries FROM dbo.Incident WHERE incident_id = 2);
UPDATE dbo.Incident SET injuries = @origInj + 1 WHERE incident_id = 2;

-- WINDOW B (step 3: 2nd read in same tran -> DIFFERENT number!)
SELECT incident_id, injuries FROM dbo.Incident WHERE incident_id = 2;
COMMIT;

-- --- Part 2: Stopped by REPEATABLE READ ---
-- WINDOW B (step 4):
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN TRAN;
SELECT incident_id, injuries FROM dbo.Incident WHERE incident_id = 2;  -- holds S-lock

-- WINDOW A (step 5: try to update -> BLOCKS until Window B commits):
UPDATE dbo.Incident SET injuries = injuries - 1 WHERE incident_id = 2;

-- WINDOW B (step 6: 2nd read is guaranteed identical, then COMMIT releases Window A):
SELECT incident_id, injuries FROM dbo.Incident WHERE incident_id = 2;
COMMIT;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO


/* ============================================================================
   (d) DEADLOCK (Error 1205) and FIX (consistent lock order + retry)
   Expected: Locking rows in opposite order (1->2 vs 2->1) causes SQL Server
   to kill one session with Msg 1205. Consistent order (1->2 in both) prevents it.
   ============================================================================ */
-- --- Step 1 (WINDOW A): lock row 1 ---
USE blackboxdb;
BEGIN TRAN;
UPDATE dbo.Incident SET injuries = injuries WHERE incident_id = 1;

-- --- Step 2 (WINDOW B): lock row 2 ---
USE blackboxdb;
BEGIN TRAN;
UPDATE dbo.Incident SET injuries = injuries WHERE incident_id = 2;

-- --- Step 3 (WINDOW A): try to lock row 2 (waits on Window B) ---
UPDATE dbo.Incident SET injuries = injuries WHERE incident_id = 2;

-- --- Step 4 (WINDOW B): try to lock row 1 -> DEADLOCK! One window gets Msg 1205 ---
UPDATE dbo.Incident SET injuries = injuries WHERE incident_id = 1;

-- Run ROLLBACK in the surviving window:
ROLLBACK;

-- --- FIX: Always acquire locks in the same order (id 1 then id 2) + 1205 retry ---
DECLARE @attempt INT = 0, @done BIT = 0;
WHILE @attempt < 3 AND @done = 0
BEGIN
    BEGIN TRY
        SET @attempt += 1;
        BEGIN TRAN;
        UPDATE dbo.Incident SET injuries = injuries WHERE incident_id = 1;
        UPDATE dbo.Incident SET injuries = injuries WHERE incident_id = 2;
        COMMIT;
        SET @done = 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() = 1205 AND @attempt < 3
            WAITFOR DELAY '00:00:00.200';
        ELSE
            THROW;
    END CATCH
END;
SELECT @attempt AS attempts_used, @done AS succeeded;
GO


/* ============================================================================
   (e) SNAPSHOT ISOLATION (readers do not block writers, writers do not block readers)
   Expected: Window B reads the last committed version immediately without waiting
   on Window A's open transaction.
   ============================================================================ */
-- --- Setup (run once) ---
ALTER DATABASE blackboxdb SET ALLOW_SNAPSHOT_ISOLATION ON;
GO

-- --- WINDOW A (step 1: update row 3 and leave transaction open) ---
USE blackboxdb;
BEGIN TRAN;
UPDATE dbo.Incident SET location = 'SNAPSHOT WRITER UNCOMMITTED' WHERE incident_id = 3;

-- --- WINDOW B (step 2: read under SNAPSHOT -> NO BLOCKING, sees old committed value) ---
USE blackboxdb;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRAN;
SELECT incident_id, location FROM dbo.Incident WHERE incident_id = 3;
COMMIT;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- --- WINDOW A (step 3: clean up) ---
ROLLBACK;
GO
