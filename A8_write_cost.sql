/* ==========================================================================
   A8_write_cost.sql  -  the COST test: indexes make reads faster but writes slower.
   Inserts 10,000 rows into a COPY of Incident (Incident_Perf: no triggers, no foreign keys, so only the indexes differ)
     A) with only the primary key         B) with 6 extra indexes (4 rowstore + 1 covering + 1 columnstore, like the real table)
   3 rounds each. The copy is dropped at the end. Your real Incident table is not touched.
   ========================================================================== */
USE blackboxdb;
GO
SET NOCOUNT ON;
DROP TABLE IF EXISTS dbo.Incident_Perf;
IF OBJECT_ID('tempdb..#cost') IS NOT NULL DROP TABLE #cost;
CREATE TABLE #cost (round INT, scenario VARCHAR(40), ms DECIMAL(10,1));
CREATE TABLE dbo.Incident_Perf (
  incident_id INT IDENTITY(1,1) PRIMARY KEY,
  aircraft_id INT NOT NULL, airport_id INT NULL, flight_id INT NULL, incident_date DATE NOT NULL, location VARCHAR(120) NOT NULL,
  phase_of_flight VARCHAR(20) NOT NULL, severity VARCHAR(20) NOT NULL, fatalities INT NOT NULL, injuries INT NOT NULL,
  passengers_on_board SMALLINT NULL, status VARCHAR(20) NOT NULL, description VARCHAR(MAX) NULL, is_deleted BIT NOT NULL, is_archived BIT NOT NULL);
GO

DECLARE @round INT = 1, @t0 DATETIME2(7);
WHILE @round <= 3
BEGIN
  ---- A) primary key only
  TRUNCATE TABLE dbo.Incident_Perf;
  SET @t0 = SYSDATETIME();
  INSERT INTO dbo.Incident_Perf(aircraft_id, airport_id, flight_id, incident_date, location, phase_of_flight, severity, fatalities, injuries,
                                passengers_on_board, status, description, is_deleted, is_archived)
  SELECT TOP (10000) aircraft_id, airport_id, flight_id, incident_date, location, phase_of_flight, severity, fatalities, injuries,
                     passengers_on_board, status, description, is_deleted, is_archived
  FROM dbo.Incident ORDER BY incident_id;
  INSERT #cost VALUES (@round, 'A: primary key only', DATEDIFF(MICROSECOND, @t0, SYSDATETIME()) / 1000.0);

  ---- B) with the extra indexes
  TRUNCATE TABLE dbo.Incident_Perf;
  CREATE INDEX ixp_date     ON dbo.Incident_Perf(incident_date) INCLUDE (severity, fatalities, is_deleted);
  CREATE INDEX ixp_sev      ON dbo.Incident_Perf(severity, status);
  CREATE INDEX ixp_location ON dbo.Incident_Perf(location);
  CREATE INDEX ixp_aircraft ON dbo.Incident_Perf(aircraft_id) INCLUDE (incident_date, severity, fatalities, is_deleted);
  CREATE INDEX ixp_phase    ON dbo.Incident_Perf(phase_of_flight);
  CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_perf ON dbo.Incident_Perf(incident_date, severity, fatalities, injuries, phase_of_flight, aircraft_id);
  SET @t0 = SYSDATETIME();
  INSERT INTO dbo.Incident_Perf(aircraft_id, airport_id, flight_id, incident_date, location, phase_of_flight, severity, fatalities, injuries,
                                passengers_on_board, status, description, is_deleted, is_archived)
  SELECT TOP (10000) aircraft_id, airport_id, flight_id, incident_date, location, phase_of_flight, severity, fatalities, injuries,
                     passengers_on_board, status, description, is_deleted, is_archived
  FROM dbo.Incident ORDER BY incident_id;
  INSERT #cost VALUES (@round, 'B: 6 extra indexes', DATEDIFF(MICROSECOND, @t0, SYSDATETIME()) / 1000.0);
  DROP INDEX ixp_date ON dbo.Incident_Perf;
  DROP INDEX ixp_sev ON dbo.Incident_Perf;
  DROP INDEX ixp_location ON dbo.Incident_Perf;
  DROP INDEX ixp_aircraft ON dbo.Incident_Perf;
  DROP INDEX ixp_phase ON dbo.Incident_Perf;
  DROP INDEX ncci_perf ON dbo.Incident_Perf;
  SET @round += 1;
END
GO
SELECT scenario, COUNT(*) AS rounds, CAST(AVG(ms) AS DECIMAL(10,1)) AS avg_ms, MIN(ms) AS best_ms, MAX(ms) AS worst_ms
FROM #cost GROUP BY scenario ORDER BY scenario;
SELECT CAST(MAX(CASE WHEN scenario LIKE 'B%' THEN a END) / NULLIF(MAX(CASE WHEN scenario LIKE 'A%' THEN a END), 0) AS DECIMAL(6,2)) AS times_slower_with_indexes
FROM (SELECT scenario, AVG(ms) AS a FROM #cost GROUP BY scenario) x;
GO
DROP TABLE dbo.Incident_Perf;
DROP TABLE #cost;
GO
