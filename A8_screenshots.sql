/* ==========================================================================
   A8_screenshots.sql  -  helper for the plan screenshots (run it block by block, do NOT press F5 on the whole file)
   Before you start:  Query menu > Include Actual Execution Plan (Ctrl+M) must be ON.
   For every block: select ONLY the lines of that step with the mouse, press F5, open the "Execution plan" tab, take the screenshot,
   name it as written in the comment. Each block starts and ends with the index dropped, so the blocks are independent.
   REQUIRED: blocks 1 to 5 (10 plan screenshots). RECOMMENDED: blocks 6, 7 and 8. OPTIONAL: block 9.
   At the very end run objects_a_A8_indexes.sql to put all indexes back.
   ========================================================================== */
USE blackboxdb;
GO
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

/* ---- STEP 0: baseline. Select these lines, press F5. No screenshot. ---- */
DROP INDEX IF EXISTS ix_incident_date       ON dbo.Incident;
DROP INDEX IF EXISTS ix_incident_sev_status ON dbo.Incident;
DROP INDEX IF EXISTS ix_incident_location   ON dbo.Incident;
DROP INDEX IF EXISTS ix_incident_aircraft   ON dbo.Incident;
DROP INDEX IF EXISTS ix_incident_isdeleted  ON dbo.Incident;
DROP INDEX IF EXISTS ncci_incident          ON dbo.Incident;
DROP INDEX IF EXISTS ix_incidentcause_cause ON dbo.Incident_Cause;
DROP INDEX IF EXISTS ix_incidentcrew_crew   ON dbo.Incident_Crew;
GO

/* ===== BLOCK 1: ix_incident_date ===== */
-- 1a BEFORE  -> A8_q1_before.png (expect Clustered Index Scan)
SELECT SUM(fatalities) FROM dbo.Incident WHERE incident_date BETWEEN '2019-01-01' AND '2019-03-31' AND is_deleted = 0;
-- 1b create the index (no screenshot)
CREATE INDEX ix_incident_date ON dbo.Incident(incident_date) INCLUDE (severity, fatalities, is_deleted);
-- 1c AFTER   -> A8_q1_after.png (expect Index Seek)
SELECT SUM(fatalities) FROM dbo.Incident WHERE incident_date BETWEEN '2019-01-01' AND '2019-03-31' AND is_deleted = 0;
-- 1d key lookup picture for the viva -> A8_keylookup.png (expect Index Seek + Key Lookup, because description is not in the index)
SELECT incident_id, incident_date, description FROM dbo.Incident WHERE incident_date BETWEEN '2019-01-01' AND '2019-01-31';
-- 1e drop (no screenshot)
DROP INDEX ix_incident_date ON dbo.Incident;
GO

/* ===== BLOCK 2: ix_incident_sev_status ===== */
-- 2a BEFORE  -> A8_q2_before.png
SELECT COUNT(*) FROM dbo.Incident WHERE severity = 'Fatal' AND status = 'Open';
-- 2b create
CREATE INDEX ix_incident_sev_status ON dbo.Incident(severity, status);
-- 2c AFTER   -> A8_q2_after.png
SELECT COUNT(*) FROM dbo.Incident WHERE severity = 'Fatal' AND status = 'Open';
-- 2d drop
DROP INDEX ix_incident_sev_status ON dbo.Incident;
GO

/* ===== BLOCK 3: ix_incident_location ===== */
-- 3a BEFORE  -> A8_q3_before.png
SELECT COUNT(*) FROM dbo.Incident WHERE location LIKE 'Cape%';
-- 3b create
CREATE INDEX ix_incident_location ON dbo.Incident(location);
-- 3c AFTER   -> A8_q3_after.png (Index Seek)
SELECT COUNT(*) FROM dbo.Incident WHERE location LIKE 'Cape%';
-- 3d leading % cannot seek -> A8_q3_leading_percent.png (Index Scan, not Seek: good viva picture)
SELECT COUNT(*) FROM dbo.Incident WHERE location LIKE '%Cape%';
-- 3e drop
DROP INDEX ix_incident_location ON dbo.Incident;
GO

/* ===== BLOCK 4: ix_incidentcause_cause ===== */
-- 4a BEFORE  -> A8_q4_before.png
SELECT COUNT(*) FROM dbo.Incident_Cause WHERE cause_id = 5;
-- 4b create
CREATE INDEX ix_incidentcause_cause ON dbo.Incident_Cause(cause_id);
-- 4c AFTER   -> A8_q4_after.png
SELECT COUNT(*) FROM dbo.Incident_Cause WHERE cause_id = 5;
-- 4d drop
DROP INDEX ix_incidentcause_cause ON dbo.Incident_Cause;
GO

/* ===== BLOCK 5: ix_incidentcrew_crew ===== */
-- 5a BEFORE  -> A8_q5_before.png
SELECT COUNT(*) FROM dbo.Incident_Crew WHERE crew_id = 7;
-- 5b create
CREATE INDEX ix_incidentcrew_crew ON dbo.Incident_Crew(crew_id);
-- 5c AFTER   -> A8_q5_after.png
SELECT COUNT(*) FROM dbo.Incident_Crew WHERE crew_id = 7;
-- 5d drop
DROP INDEX ix_incidentcrew_crew ON dbo.Incident_Crew;
GO

/* ===== BLOCK 6 (recommended): ix_incident_aircraft, the biggest win (22,284 -> 1,676 reads) ===== */
-- 6a BEFORE  -> A8_q6_before.png
SELECT COUNT(*) FROM dbo.v_aircraft_risk WHERE raw_total >= 0;
-- 6b create
CREATE INDEX ix_incident_aircraft ON dbo.Incident(aircraft_id) INCLUDE (incident_date, severity, fatalities, is_deleted);
-- 6c AFTER   -> A8_q6_after.png
SELECT COUNT(*) FROM dbo.v_aircraft_risk WHERE raw_total >= 0;
-- 6d drop
DROP INDEX ix_incident_aircraft ON dbo.Incident;
GO

-- 7-create (no screenshot)
CREATE INDEX ix_incident_isdeleted ON dbo.Incident(is_deleted);
GO
-- 7a normal query: the index is ignored -> A8_q7_ignored.png (expect Clustered Index Scan)
SELECT SUM(injuries) FROM dbo.Incident WHERE is_deleted = 0;
-- 7b forced with a hint -> A8_q7_forced.png (expect Index Seek plus a huge number of Key Lookups)
SELECT SUM(injuries) FROM dbo.Incident WITH (INDEX(ix_incident_isdeleted)) WHERE is_deleted = 0;
-- 7-drop (no screenshot)
DROP INDEX ix_incident_isdeleted ON dbo.Incident;
GO
/* ===== BLOCK 8 (recommended): columnstore bonus ===== */
-- 8a BEFORE  -> A8_q8_before.png
SELECT COUNT(*) FROM (SELECT YEAR(incident_date) AS y, severity, SUM(fatalities) AS f, SUM(injuries) AS i, COUNT(*) AS c FROM dbo.Incident GROUP BY YEAR(incident_date), severity) g;
-- 8b create
CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_incident ON dbo.Incident(incident_date, severity, fatalities, injuries, phase_of_flight, aircraft_id);
-- 8c AFTER   -> A8_q8_after.png (Columnstore Index Scan)
SELECT COUNT(*) FROM (SELECT YEAR(incident_date) AS y, severity, SUM(fatalities) AS f, SUM(injuries) AS i, COUNT(*) AS c FROM dbo.Incident GROUP BY YEAR(incident_date), severity) g;
-- 8d drop
DROP INDEX ncci_incident ON dbo.Incident;
GO

/* ===== BLOCK 9 (optional): the Messages tab with the logical reads ===== */
-- After any run above, click the "Messages" tab and screenshot it: it shows "logical reads" and "elapsed time" for that query.

/* ===== LAST STEP: put all final indexes back ===== */
-- Open objects_a_A8_indexes.sql and run it with F5. Then check:
-- SELECT name, OBJECT_NAME(object_id) AS on_table FROM sys.indexes WHERE name LIKE 'ix[_]incident%' OR name LIKE 'ncci%';
