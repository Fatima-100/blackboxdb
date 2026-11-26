/* ==========================================================================
   objects_a_A8_indexes.sql  -  BlackBox DB, Member A, task A8: the indexes (final versions, no measuring)
   Run with blackboxdb selected. Safe to run again (each index is created only if it is missing).
   Indexes:  ix_incident_date, ix_incident_sev_status, ix_incident_location, ix_incidentcause_cause, ix_incidentcrew_crew,
             ix_incident_aircraft (extra: supports fn_AircraftRiskScore / v_aircraft_risk),
             full-text index on Incident(description) in catalog ftc_blackbox (only when full-text is installed),
             ncci_incident (nonclustered columnstore, bonus).
   NOT created on purpose: an index on Incident(is_deleted) - it is the "index that does not help" in A8_proof.sql.
   ========================================================================== */
USE blackboxdb;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- What: covering index on the incident date; INCLUDE adds severity, fatalities, is_deleted to the leaf level.
-- Why:  "incidents between two dates" and yearly totals read only this index (a seek on the date range, no lookup into the table).
-- Who:  Member A
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_incident_date' AND object_id = OBJECT_ID('dbo.Incident'))
  CREATE INDEX ix_incident_date ON dbo.Incident(incident_date) INCLUDE (severity, fatalities, is_deleted);

-- What: composite index (severity, status).
-- Why:  dashboard filters such as "Fatal AND Open"; severity first because it is used alone too (leftmost-prefix rule).
-- Who:  Member A
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_incident_sev_status' AND object_id = OBJECT_ID('dbo.Incident'))
  CREATE INDEX ix_incident_sev_status ON dbo.Incident(severity, status);

-- What: nonclustered index on location.
-- Why:  a prefix search (LIKE 'Cape%') becomes an index range seek; a search with a leading % (LIKE '%Cape%') can NOT use it.
-- Who:  Member A
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_incident_location' AND object_id = OBJECT_ID('dbo.Incident'))
  CREATE INDEX ix_incident_location ON dbo.Incident(location);

-- What: index on the cause side of the Incident_Cause link table.
-- Why:  its primary key starts with incident_id, so "all incidents of one cause" had to scan the whole table; this is the reverse side of the foreign key.
-- Who:  Member A
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_incidentcause_cause' AND object_id = OBJECT_ID('dbo.Incident_Cause'))
  CREATE INDEX ix_incidentcause_cause ON dbo.Incident_Cause(cause_id);

-- What: index on the crew side of the Incident_Crew link table.
-- Why:  same reason: "all incidents of one crew member" (the primary key starts with incident_id).
-- Who:  Member A
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_incidentcrew_crew' AND object_id = OBJECT_ID('dbo.Incident_Crew'))
  CREATE INDEX ix_incidentcrew_crew ON dbo.Incident_Crew(crew_id);

-- What: foreign-key index on Incident(aircraft_id) with the columns the risk score reads.
-- Why:  fn_AircraftRiskBreakdown looks up the incidents of ONE aircraft once per aircraft; without this index each lookup scans all incidents.
-- Who:  Member A
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_incident_aircraft' AND object_id = OBJECT_ID('dbo.Incident'))
  CREATE INDEX ix_incident_aircraft ON dbo.Incident(aircraft_id) INCLUDE (incident_date, severity, fatalities, is_deleted);

-- What: nonclustered columnstore index on the columns used by big GROUP BY reports (bonus).
-- Why:  stores each column separately and compressed, so a report that groups millions of rows reads only the needed columns.
--       It makes INSERT/UPDATE a little slower (see A8_write_cost.sql).
-- Who:  Member A
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ncci_incident' AND object_id = OBJECT_ID('dbo.Incident'))
  CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_incident ON dbo.Incident(incident_date, severity, fatalities, injuries, phase_of_flight, aircraft_id);
GO

/* ---------- full-text index (only if the Full-Text feature is installed) ---------- */
-- What: full-text index on Incident(description) in the catalog ftc_blackbox.
-- Why:  CONTAINS(description, 'engine AND failure') finds words with a word index instead of scanning every description with LIKE '%word%'.
-- Who:  Member A
DECLARE @ft INT = CAST(FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') AS INT);
IF @ft <> 1
  PRINT 'Full-text is NOT installed on this SQL Server (IsFullTextInstalled = ' + CAST(@ft AS VARCHAR(5)) + '). Skipped: keep the LIKE search and write this in index_proof_a.md.';
ELSE IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('dbo.Incident'))
BEGIN
  DECLARE @pk SYSNAME = (SELECT name FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Incident') AND is_primary_key = 1);
  IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'ftc_blackbox') EXEC (N'CREATE FULLTEXT CATALOG ftc_blackbox;');
  EXEC (N'CREATE FULLTEXT INDEX ON dbo.Incident(description) KEY INDEX ' + @pk + N' ON ftc_blackbox WITH CHANGE_TRACKING AUTO;');
  PRINT 'Full-text index created; it fills in the background for a few seconds.';
END
GO
PRINT 'A8 indexes done.';
GO
