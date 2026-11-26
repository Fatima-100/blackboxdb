/* ============================================================================
   sql_lab.sql  -  A9: SQL Lab (DML, DDL, transactions, functions)
   Works ONLY on test copies (Incident_Test, lab_* tables). Real tables are
   only read. Run the whole file in SSMS with your BlackBox database selected.
   It can be run again and again; it cleans up after itself at the end.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT OFF;

-- ---------- 0. SETUP: copy the structure, then fill from the real table ------
IF OBJECT_ID('dbo.Incident_Test') IS NOT NULL DROP TABLE dbo.Incident_Test;
IF OBJECT_ID('dbo.lab_fatal_copy') IS NOT NULL DROP TABLE dbo.lab_fatal_copy;
IF OBJECT_ID('dbo.lab_note')       IS NOT NULL DROP TABLE dbo.lab_note;
IF OBJECT_ID('dbo.seq_lab_note')   IS NOT NULL DROP SEQUENCE dbo.seq_lab_note;
IF OBJECT_ID('tempdb..#changes')   IS NOT NULL DROP TABLE #changes;

-- CAST(...) makes incident_id a plain INT, so the copy has no IDENTITY and no triggers or constraints.
SELECT CAST(incident_id AS INT) AS incident_id, aircraft_id, incident_date, location,
       phase_of_flight, severity, fatalities, injuries, status
  INTO dbo.Incident_Test
  FROM dbo.Incident
 WHERE 1 = 0;

INSERT INTO dbo.Incident_Test
SELECT TOP (500) incident_id, aircraft_id, incident_date, location,
       phase_of_flight, severity, fatalities, injuries, status
  FROM dbo.Incident WHERE is_deleted = 0 ORDER BY incident_id;

SELECT 'SETUP: rows in Incident_Test' AS step, COUNT(*) AS result FROM dbo.Incident_Test;

DECLARE @ac INT = (SELECT TOP 1 aircraft_id FROM dbo.Aircraft ORDER BY aircraft_id);

/* ============================ 1. DML ====================================== */
-- 1a INSERT (one row)
INSERT INTO dbo.Incident_Test (incident_id, aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, status)
VALUES (900001, @ac, '2024-05-01', 'Lab Airport', 'Cruise', 'Minor', 0, 1, 'Open');
SELECT '1a INSERT one row' AS step, * FROM dbo.Incident_Test WHERE incident_id = 900001;

-- 1b INSERT ... SELECT (copy 3 rows under new ids)
INSERT INTO dbo.Incident_Test (incident_id, aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, status)
SELECT TOP (3) incident_id + 1000000, aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, status
  FROM dbo.Incident_Test WHERE incident_id < 900000 ORDER BY incident_id;
SELECT '1b INSERT ... SELECT' AS step, COUNT(*) AS rows_with_new_ids FROM dbo.Incident_Test WHERE incident_id BETWEEN 1000000 AND 1999999;

-- 1c UPDATE with a JOIN (reads real Aircraft, changes only the test table)
UPDATE t SET t.location = CONCAT(a.registration_no, ' area')
  FROM dbo.Incident_Test t JOIN dbo.Aircraft a ON a.aircraft_id = t.aircraft_id
 WHERE t.incident_id IN (SELECT TOP (3) incident_id FROM dbo.Incident_Test WHERE incident_id < 900000 ORDER BY incident_id);
SELECT TOP (3) '1c UPDATE with JOIN' AS step, incident_id, location FROM dbo.Incident_Test WHERE incident_id < 900000 ORDER BY incident_id;

-- 1d DELETE (remove the 3 copies from 1b)
DELETE FROM dbo.Incident_Test WHERE incident_id BETWEEN 1000000 AND 1999999;
SELECT '1d DELETE' AS step, COUNT(*) AS copies_left FROM dbo.Incident_Test WHERE incident_id BETWEEN 1000000 AND 1999999;

-- 1e MERGE with OUTPUT: update matches, insert new, delete rows missing from the source (only ids 4..6)
CREATE TABLE #changes (incident_id INT PRIMARY KEY, severity VARCHAR(10) NOT NULL);
INSERT #changes VALUES (1, 'Major'),     -- matches: UPDATE
                       (2, 'Serious'),   -- matches: UPDATE
                       (900002, 'Fatal'),-- new: INSERT
                       (3, 'Minor');     -- matches: UPDATE (ids 4,5,6 are not in the source: DELETE)
DECLARE @log TABLE (merge_action NVARCHAR(10), new_id INT, old_id INT, old_sev VARCHAR(10), new_sev VARCHAR(10));
MERGE dbo.Incident_Test AS t
USING #changes AS s ON t.incident_id = s.incident_id
WHEN MATCHED AND t.severity <> s.severity THEN
     UPDATE SET t.severity = s.severity
WHEN NOT MATCHED BY TARGET THEN
     INSERT (incident_id, aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, status)
     VALUES (s.incident_id, @ac, '2024-06-01', 'Merge Airport', 'Landing', s.severity, 1, 0, 'Open')
WHEN NOT MATCHED BY SOURCE AND t.incident_id BETWEEN 4 AND 6 THEN
     DELETE
OUTPUT $action, inserted.incident_id, deleted.incident_id, deleted.severity, inserted.severity INTO @log;
SELECT '1e MERGE OUTPUT' AS step, * FROM @log ORDER BY merge_action;

-- 1f SELECT INTO (new table from a query)
SELECT incident_id, incident_date, severity, fatalities INTO dbo.lab_fatal_copy FROM dbo.Incident_Test WHERE severity = 'Fatal';
SELECT '1f SELECT INTO' AS step, COUNT(*) AS rows_copied FROM dbo.lab_fatal_copy;

-- 1g TRUNCATE TABLE (only allowed here because it is the test copy)
TRUNCATE TABLE dbo.lab_fatal_copy;
SELECT '1g TRUNCATE' AS step, COUNT(*) AS rows_left FROM dbo.lab_fatal_copy;

/* ============================ 2. DDL ====================================== */
-- 2a CREATE TABLE
CREATE TABLE dbo.lab_note (note_id INT NOT NULL PRIMARY KEY, note_text VARCHAR(50) NOT NULL);
-- 2b ALTER TABLE ADD COLUMN
ALTER TABLE dbo.lab_note ADD priority INT NOT NULL CONSTRAINT df_lab_note_priority DEFAULT 1;
-- 2c ALTER COLUMN (make the text longer)
ALTER TABLE dbo.lab_note ALTER COLUMN note_text VARCHAR(200) NOT NULL;
-- 2d ADD CONSTRAINT
ALTER TABLE dbo.lab_note ADD CONSTRAINT ck_lab_note_priority CHECK (priority BETWEEN 1 AND 5);
BEGIN TRY INSERT dbo.lab_note (note_id, note_text, priority) VALUES (1, 'too urgent', 9);
          SELECT '2d constraint did NOT block' AS step;
END TRY BEGIN CATCH SELECT '2d constraint blocked priority 9' AS step, ERROR_MESSAGE() AS message; END CATCH
-- 2e DROP CONSTRAINT
ALTER TABLE dbo.lab_note DROP CONSTRAINT ck_lab_note_priority;
INSERT dbo.lab_note (note_id, note_text, priority) VALUES (1, 'priority 9 now allowed', 9);
SELECT '2e after DROP CONSTRAINT' AS step, * FROM dbo.lab_note;
-- 2f SEQUENCE + NEXT VALUE FOR
CREATE SEQUENCE dbo.seq_lab_note AS INT START WITH 100 INCREMENT BY 10;
INSERT dbo.lab_note (note_id, note_text) VALUES (NEXT VALUE FOR dbo.seq_lab_note, 'first from sequence');
INSERT dbo.lab_note (note_id, note_text) VALUES (NEXT VALUE FOR dbo.seq_lab_note, 'second from sequence');
SELECT '2f SEQUENCE (100, 110)' AS step, * FROM dbo.lab_note ORDER BY note_id;
-- 2g DROP TABLE and SEQUENCE
DROP TABLE dbo.lab_note;
DROP SEQUENCE dbo.seq_lab_note;
SELECT '2g DROP' AS step, OBJECT_ID('dbo.lab_note') AS table_id_should_be_NULL;

/* ======================== 3. TRANSACTIONS ================================= */
DECLARE @sev1 VARCHAR(10), @sev2 VARCHAR(10);
SELECT '3 start' AS step, incident_id, severity FROM dbo.Incident_Test WHERE incident_id IN (1, 2);

-- 3a ROLLBACK undoes everything
BEGIN TRAN;
  UPDATE dbo.Incident_Test SET severity = 'Fatal' WHERE incident_id IN (1, 2);
  SELECT '3a inside the transaction' AS step, incident_id, severity FROM dbo.Incident_Test WHERE incident_id IN (1, 2);
ROLLBACK;
SELECT '3a after ROLLBACK (back to start)' AS step, incident_id, severity FROM dbo.Incident_Test WHERE incident_id IN (1, 2);

-- 3b COMMIT keeps the change
BEGIN TRAN;
  UPDATE dbo.Incident_Test SET injuries = injuries + 10 WHERE incident_id = 1;
COMMIT;
SELECT '3b after COMMIT (injuries +10)' AS step, incident_id, injuries FROM dbo.Incident_Test WHERE incident_id = 1;

-- 3c SAVE TRAN and partial rollback: step A is kept, step B is undone
BEGIN TRAN;
  UPDATE dbo.Incident_Test SET location = 'STEP A' WHERE incident_id = 1;
  SAVE TRAN after_step_a;
  UPDATE dbo.Incident_Test SET location = 'STEP B' WHERE incident_id = 2;
  SELECT '3c both steps done' AS step, incident_id, location FROM dbo.Incident_Test WHERE incident_id IN (1, 2);
  ROLLBACK TRAN after_step_a;
  SELECT '3c after partial rollback (B undone, A kept)' AS step, incident_id, location FROM dbo.Incident_Test WHERE incident_id IN (1, 2);
COMMIT;
SELECT '3c after COMMIT' AS step, incident_id, location, @@TRANCOUNT AS open_transactions FROM dbo.Incident_Test WHERE incident_id IN (1, 2);

/* ===================== 4. FUNCTIONS INSIDE QUERIES ======================== */
SELECT TOP (5)
    incident_id,
    -- CASE / IIF / COALESCE / ISNULL / NULLIF
    CASE WHEN fatalities = 0 THEN 'No deaths' WHEN fatalities < 10 THEN 'Few' ELSE 'Many' END AS case_demo,
    IIF(severity IN ('Major', 'Fatal'), 'High', 'Low')                       AS iif_demo,
    COALESCE(NULL, location, 'unknown')                                      AS coalesce_demo,
    ISNULL(NULL, 'default')                                                  AS isnull_demo,
    NULLIF(fatalities, 0)                                                    AS nullif_zero_becomes_NULL,
    -- strings
    UPPER(location)                                                          AS upper_demo,
    SUBSTRING(location, 1, 5)                                                AS substring_demo,
    CONCAT(severity, ' / ', phase_of_flight)                                 AS concat_demo,
    LEN(location)                                                            AS len_demo,
    -- dates
    DATEDIFF(YEAR, incident_date, GETDATE())                                 AS years_ago,
    DATEADD(MONTH, 6, incident_date)                                         AS plus_6_months,
    EOMONTH(incident_date)                                                   AS month_end,
    FORMAT(incident_date, 'dd MMM yyyy')                                     AS formatted_date,
    -- numbers and conversion
    ROUND(fatalities / 3.0, 1)                                               AS round_demo,
    CAST(fatalities AS VARCHAR(10)) + ' dead'                                AS cast_demo,
    CONVERT(VARCHAR(10), incident_date, 103)                                 AS convert_dd_mm_yyyy
FROM dbo.Incident_Test
WHERE incident_id < 900000
ORDER BY incident_id;

/* ============================== CLEAN UP ================================== */
DROP TABLE IF EXISTS dbo.lab_fatal_copy;
DROP TABLE IF EXISTS dbo.Incident_Test;
DROP TABLE IF EXISTS #changes;
SELECT 'DONE: test tables removed, real tables untouched' AS step,
       (SELECT COUNT(*) FROM dbo.Incident) AS real_incident_rows;
