/* ==========================================================================
   A8_proof.sql  -  measures every index BEFORE and AFTER (logical reads and milliseconds) and prints a table for index_proof_a.md
   Run the WHOLE file once (F5, takes about a minute). Do not run other queries on this server at the same time.
   What it does for each index, one at a time:
     1. makes sure the A8 indexes are gone (baseline)   2. runs the query twice and measures the second (warm) run   -> "before"
     3. creates the index   4. measures again   -> "after"   5. drops the index again so the next test starts clean
   At the end it creates all the final indexes again (everything except the "does not help" one).
   Reads come from sys.dm_exec_requests.logical_reads for this session, so they can differ by a few pages from SET STATISTICS IO.
   For the screenshots, run the query yourself with the actual execution plan on (see index_proof_a.md).
   ========================================================================== */
USE blackboxdb;
GO
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;
GO
/* ---- 0. baseline: drop every A8 index (the table is the same as the one in schema_incident.sql) ---- */
DROP INDEX IF EXISTS ix_incident_date       ON dbo.Incident;
DROP INDEX IF EXISTS ix_incident_sev_status ON dbo.Incident;
DROP INDEX IF EXISTS ix_incident_location   ON dbo.Incident;
DROP INDEX IF EXISTS ix_incident_aircraft   ON dbo.Incident;
DROP INDEX IF EXISTS ix_incident_isdeleted  ON dbo.Incident;
DROP INDEX IF EXISTS ncci_incident          ON dbo.Incident;
DROP INDEX IF EXISTS ix_incidentcause_cause ON dbo.Incident_Cause;
DROP INDEX IF EXISTS ix_incidentcrew_crew   ON dbo.Incident_Crew;
IF EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('dbo.Incident')) DROP FULLTEXT INDEX ON dbo.Incident;
IF EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'ftc_blackbox') DROP FULLTEXT CATALOG ftc_blackbox;
GO

/* ---- 1. the test list ---- */
IF OBJECT_ID('tempdb..#q') IS NOT NULL DROP TABLE #q;
IF OBJECT_ID('tempdb..#proof') IS NOT NULL DROP TABLE #proof;
IF OBJECT_ID('tempdb..#sink') IS NOT NULL DROP TABLE #sink;
CREATE TABLE #q (id INT PRIMARY KEY, label VARCHAR(90), index_name VARCHAR(40), is_ft BIT NOT NULL DEFAULT 0, keep BIT NOT NULL DEFAULT 1,
                 sql_before NVARCHAR(MAX), sql_after NVARCHAR(MAX), sql_forced NVARCHAR(MAX), create_sql NVARCHAR(MAX), drop_sql NVARCHAR(MAX));
CREATE TABLE #proof (id INT, phase VARCHAR(10), reads BIGINT, ms DECIMAL(10,2));
CREATE TABLE #sink (v FLOAT);

DECLARE @pk SYSNAME = (SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Incident') AND is_primary_key = 1);

INSERT #q(id, label, index_name, sql_before, create_sql, drop_sql) VALUES
(1, 'Fatalities in one quarter (date range)', 'ix_incident_date',
 N'SELECT SUM(fatalities) FROM dbo.Incident WHERE incident_date BETWEEN ''2019-01-01'' AND ''2019-03-31'' AND is_deleted = 0',
 N'CREATE INDEX ix_incident_date ON dbo.Incident(incident_date) INCLUDE (severity, fatalities, is_deleted)',
 N'DROP INDEX ix_incident_date ON dbo.Incident'),
(2, 'Count of Fatal incidents that are Open (dashboard filter)', 'ix_incident_sev_status',
 N'SELECT COUNT(*) FROM dbo.Incident WHERE severity = ''Fatal'' AND status = ''Open''',
 N'CREATE INDEX ix_incident_sev_status ON dbo.Incident(severity, status)',
 N'DROP INDEX ix_incident_sev_status ON dbo.Incident'),
(3, 'Prefix search: location LIKE ''Cape%''', 'ix_incident_location',
 N'SELECT COUNT(*) FROM dbo.Incident WHERE location LIKE ''Cape%''',
 N'CREATE INDEX ix_incident_location ON dbo.Incident(location)',
 N'DROP INDEX ix_incident_location ON dbo.Incident'),
(4, 'Incidents of one cause (reverse side of the foreign key)', 'ix_incidentcause_cause',
 N'SELECT COUNT(*) FROM dbo.Incident_Cause WHERE cause_id = 5',
 N'CREATE INDEX ix_incidentcause_cause ON dbo.Incident_Cause(cause_id)',
 N'DROP INDEX ix_incidentcause_cause ON dbo.Incident_Cause'),
(5, 'Incidents of one crew member (reverse side of the foreign key)', 'ix_incidentcrew_crew',
 N'SELECT COUNT(*) FROM dbo.Incident_Crew WHERE crew_id = 7',
 N'CREATE INDEX ix_incidentcrew_crew ON dbo.Incident_Crew(crew_id)',
 N'DROP INDEX ix_incidentcrew_crew ON dbo.Incident_Crew'),
(8, 'Risk of every aircraft (v_aircraft_risk, extra index for the A6 fix)', 'ix_incident_aircraft',
 N'SELECT COUNT(*) FROM dbo.v_aircraft_risk WHERE raw_total >= 0',
 N'CREATE INDEX ix_incident_aircraft ON dbo.Incident(aircraft_id) INCLUDE (incident_date, severity, fatalities, is_deleted)',
 N'DROP INDEX ix_incident_aircraft ON dbo.Incident'),
(7, 'Big GROUP BY report (year, severity) - columnstore bonus', 'ncci_incident',
 N'SELECT COUNT(*) FROM (SELECT YEAR(incident_date) AS y, severity, SUM(fatalities) AS f, SUM(injuries) AS i, COUNT(*) AS c FROM dbo.Incident GROUP BY YEAR(incident_date), severity) g',
 N'CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_incident ON dbo.Incident(incident_date, severity, fatalities, injuries, phase_of_flight, aircraft_id)',
 N'DROP INDEX ncci_incident ON dbo.Incident');

-- 6 = full-text: before = LIKE with leading %, after = CONTAINS
INSERT #q(id, label, index_name, is_ft, sql_before, sql_after, create_sql, drop_sql) VALUES
(6, 'Word search in description: LIKE ''%engine%'' AND ''%failure%'' versus CONTAINS', 'ftc_blackbox (full-text)', 1,
 N'SELECT COUNT(*) FROM dbo.Incident WHERE description LIKE ''%engine%'' AND description LIKE ''%failure%''',
 N'SELECT COUNT(*) FROM dbo.Incident WHERE CONTAINS(description, ''engine AND failure'')',
 N'CREATE FULLTEXT CATALOG ftc_blackbox; CREATE FULLTEXT INDEX ON dbo.Incident(description) KEY INDEX ' + QUOTENAME(@pk) + N' ON ftc_blackbox WITH CHANGE_TRACKING AUTO;',
 N'DROP FULLTEXT INDEX ON dbo.Incident; DROP FULLTEXT CATALOG ftc_blackbox;');

-- 9 = the index that does NOT help (is_deleted has only 2 values and almost every row has 0)
INSERT #q(id, label, index_name, keep, sql_before, sql_forced, create_sql, drop_sql) VALUES
(9, 'Index that does NOT help: is_deleted = 0 matches almost every row', 'ix_incident_isdeleted', 0,
 N'SELECT SUM(injuries) FROM dbo.Incident WHERE is_deleted = 0',
 N'SELECT SUM(injuries) FROM dbo.Incident WITH (INDEX(ix_incident_isdeleted)) WHERE is_deleted = 0',
 N'CREATE INDEX ix_incident_isdeleted ON dbo.Incident(is_deleted)',
 N'DROP INDEX ix_incident_isdeleted ON dbo.Incident');

-- skip what this server cannot do
IF CAST(FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') AS INT) <> 1
BEGIN
  DELETE FROM #q WHERE id = 6;
  PRINT 'Full-text is not installed here: test 6 skipped. Write this in index_proof_a.md and keep the LIKE search.';
END
IF OBJECT_ID('dbo.v_aircraft_risk', 'V') IS NULL
BEGIN
  DELETE FROM #q WHERE id = 8;
  PRINT 'v_aircraft_risk does not exist (run the fixed objects_a_A6.sql): test 8 skipped.';
END
GO

/* ---- 2. the measuring loop ---- */
DECLARE @id INT = 0, @phase INT, @label VARCHAR(90), @is_ft BIT, @b NVARCHAR(MAX), @a NVARCHAR(MAX), @f NVARCHAR(MAX), @c NVARCHAR(MAX), @d NVARCHAR(MAX);
DECLARE @run NVARCHAR(MAX), @pname VARCHAR(10), @r0 BIGINT, @r1 BIGINT, @t0 DATETIME2(7), @t1 DATETIME2(7), @wait INT;

WHILE 1 = 1
BEGIN
  SELECT TOP (1) @id = id, @label = label, @is_ft = is_ft, @b = sql_before, @a = sql_after, @f = sql_forced, @c = create_sql, @d = drop_sql
  FROM #q WHERE id > @id ORDER BY id;
  IF @@ROWCOUNT = 0 BREAK;

  SET @phase = 1;
  WHILE @phase <= 3
  BEGIN
    SET @pname = CASE @phase WHEN 1 THEN 'before' WHEN 2 THEN 'after' ELSE 'forced' END;
    IF @phase = 2                                              -- create the index, then wait for the full-text fill if needed
    BEGIN
      EXEC (@c);
      IF @is_ft = 1
      BEGIN
        SET @wait = 0;
        WHILE FULLTEXTCATALOGPROPERTY('ftc_blackbox', 'PopulateStatus') <> 0 AND @wait < 120
        BEGIN WAITFOR DELAY '00:00:01'; SET @wait += 1; END
      END
    END
    SET @run = CASE @phase WHEN 1 THEN @b WHEN 2 THEN COALESCE(@a, @b) ELSE @f END;
    IF @run IS NOT NULL
    BEGIN
      INSERT #sink EXEC sys.sp_executesql @run;                -- warm-up run (plan compiled, pages in memory)
      SET @r0 = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID);
      SET @t0 = SYSDATETIME();
      INSERT #sink EXEC sys.sp_executesql @run;                -- the measured run
      SET @t1 = SYSDATETIME();
      SET @r1 = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID);
      INSERT #proof(id, phase, reads, ms) VALUES (@id, @pname, @r1 - @r0, DATEDIFF(MICROSECOND, @t0, @t1) / 1000.0);
    END
    SET @phase += 1;
  END
  EXEC (@d);                                                   -- back to baseline for the next test
END
GO

/* ---- 3. the result table (copy the last column into index_proof_a.md) ---- */
SELECT q.id, q.index_name, q.label,
       MAX(CASE WHEN p.phase = 'before' THEN p.reads END) AS reads_before,
       MAX(CASE WHEN p.phase = 'after'  THEN p.reads END) AS reads_after,
       MAX(CASE WHEN p.phase = 'before' THEN p.ms END)    AS ms_before,
       MAX(CASE WHEN p.phase = 'after'  THEN p.ms END)    AS ms_after,
       MAX(CASE WHEN p.phase = 'forced' THEN p.reads END) AS reads_forced_index,
       CONCAT('| ', q.label, ' | ', q.index_name, ' | ',
              MAX(CASE WHEN p.phase = 'before' THEN p.reads END), ' | ', MAX(CASE WHEN p.phase = 'after' THEN p.reads END), ' | ',
              MAX(CASE WHEN p.phase = 'before' THEN p.ms END), ' | ', MAX(CASE WHEN p.phase = 'after' THEN p.ms END), ' |') AS markdown_row
FROM #q q LEFT JOIN #proof p ON p.id = q.id
GROUP BY q.id, q.index_name, q.label
ORDER BY q.id;
GO

/* ---- 4. create the final indexes again (all except the one that does not help) ---- */
DECLARE @id INT = 0, @c NVARCHAR(MAX), @is_ft BIT, @wait INT = 0;
WHILE 1 = 1
BEGIN
  SELECT TOP (1) @id = id, @c = create_sql, @is_ft = is_ft FROM #q WHERE id > @id AND keep = 1 ORDER BY id;
  IF @@ROWCOUNT = 0 BREAK;
  EXEC (@c);
  IF @is_ft = 1
    WHILE FULLTEXTCATALOGPROPERTY('ftc_blackbox', 'PopulateStatus') <> 0 AND @wait < 120
    BEGIN WAITFOR DELAY '00:00:01'; SET @wait += 1; END
END
SELECT i.name AS index_name, OBJECT_NAME(i.object_id) AS on_table, i.type_desc
FROM sys.indexes i
WHERE i.name IN ('ix_incident_date', 'ix_incident_sev_status', 'ix_incident_location', 'ix_incidentcause_cause', 'ix_incidentcrew_crew',
                 'ix_incident_aircraft', 'ncci_incident', 'ix_incident_isdeleted')
ORDER BY i.name;
GO
