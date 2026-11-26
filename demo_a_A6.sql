/* demo_a_A6.sql - tests for the A6 functions. Run after objects_a_A6.sql. Expect 15 PASS.
   Test rows use the names 'TEST-A6-...' / 'TEST A6 ...' and are removed at the start and end.
   The cleanup disables trg_incident_softdelete for a moment (A7), because with it on, DELETE on Incident only sets is_deleted = 1. */
USE blackboxdb;
GO
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (no INT, test VARCHAR(80), result VARCHAR(4), detail VARCHAR(250));
GO
/* ---- cleanup of old test rows ---- */
DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;   -- real delete for test rows (the trigger would only mark them deleted)
DELETE FROM dbo.Audit_Log WHERE table_name = 'Incident' AND record_id IN
  (SELECT incident_id FROM dbo.Incident WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A6-%'));
DELETE FROM dbo.Incident WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A6-%');
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM dbo.Maintenance_Record WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A6-%');
DELETE FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A6-%';
DELETE FROM dbo.Airport WHERE name LIKE 'TEST A6%';
DELETE FROM dbo.Aircraft_Type WHERE manufacturer = 'TESTMAKER6';
DELETE FROM dbo.Airline WHERE name LIKE 'TEST A6%';
GO
/* ---- fixtures ---- */
DECLARE @today DATE = CAST(GETDATE() AS DATE);
DECLARE @yr INT = YEAR(GETDATE());
INSERT INTO dbo.Airline(name, country) VALUES ('TEST A6 Air', 'Testland');
INSERT INTO dbo.Aircraft_Type(manufacturer, model, category_id)
  SELECT 'TESTMAKER6', 'TESTMODEL6', MIN(category_id) FROM dbo.Aircraft_Category;
INSERT INTO dbo.Airport(name, country, latitude, longitude) VALUES ('TEST A6 Airport', 'Testland', 10, 10);

DECLARE @al INT = (SELECT airline_id FROM dbo.Airline WHERE name = 'TEST A6 Air');
DECLARE @ty INT = (SELECT type_id FROM dbo.Aircraft_Type WHERE model = 'TESTMODEL6');
INSERT INTO dbo.Aircraft(registration_no, airline_id, type_id, year_built) VALUES
  ('TEST-A6-R1', @al, @ty, @yr - 30),   -- risk example: age 30
  ('TEST-A6-R2', @al, @ty, @yr - 30),   -- cap example
  ('TEST-A6-R3', @al, @ty, @yr),        -- clean aircraft
  ('TEST-A6-R4', @al, @ty, @yr),        -- old maintenance overdue but latest one is not
  ('TEST-A6-S1', @al, @ty, 2010),       -- similarity pair
  ('TEST-A6-S2', @al, @ty, 2010);

DECLARE @r1 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-R1');
DECLARE @r2 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-R2');
DECLARE @r4 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-R4');
DECLARE @s1 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-S1');
DECLARE @s2 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-S2');
DECLARE @ap INT = (SELECT airport_id FROM dbo.Airport WHERE name = 'TEST A6 Airport');
DECLARE @cause INT = (SELECT MIN(cause_id) FROM dbo.Cause);

-- R1: expected score 65.0 = (Fatal 10 + Minor 1) * 4 = 44, + 2 fatalities * 0.5 = 1, + age 30 / 3 = 10, + overdue 10
INSERT INTO dbo.Incident(aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, description) VALUES
  (@r1, DATEADD(YEAR, -1, @today),  'TEST A6', 'Cruise',  'Fatal',   2, 'A6TEST in window'),
  (@r1, DATEADD(YEAR, -2, @today),  'TEST A6', 'Taxi',    'Minor',   0, 'A6TEST in window'),
  (@r1, DATEADD(YEAR, -12, @today), 'TEST A6', 'Landing', 'Serious', 0, 'A6TEST too old, must not count');
INSERT INTO dbo.Incident(aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, description, is_deleted, deleted_at)
  VALUES (@r1, DATEADD(YEAR, -1, @today), 'TEST A6', 'Climb', 'Fatal', 5, 'A6TEST soft-deleted, must not count', 1, SYSDATETIME());
INSERT INTO dbo.Maintenance_Record(aircraft_id, maint_date, maint_type, next_due_date) VALUES
  (@r1, DATEADD(YEAR, -3, @today),  'Routine', DATEADD(YEAR, -2, @today)),
  (@r1, DATEADD(MONTH, -6, @today), 'Routine', DATEADD(DAY, -1, @today));      -- latest record is overdue

-- R2: 12 fatal incidents in the window = 480 + 6 points, must be capped at 100
INSERT INTO dbo.Incident(aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, description)
  SELECT @r2, DATEADD(DAY, -10 * n, @today), 'TEST A6', 'Cruise', 'Fatal', 1, 'A6TEST cap'
  FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12)) v(n);

-- R4: the OLD record is overdue, the LATEST one is not: no overdue points
INSERT INTO dbo.Maintenance_Record(aircraft_id, maint_date, maint_type, next_due_date) VALUES
  (@r4, DATEADD(YEAR, -3, @today),  'Routine', DATEADD(YEAR, -2, @today)),
  (@r4, DATEADD(MONTH, -1, @today), 'Routine', DATEADD(YEAR, 1, @today));

-- similarity: X (the incident we ask about), Y (same everything), Z (same everything but soft-deleted)
INSERT INTO dbo.Incident(aircraft_id, airport_id, incident_date, location, phase_of_flight, severity, description) VALUES
  (@s1, @ap, '2022-01-01', 'TEST A6', 'Approach', 'Minor', 'A6TEST X'),
  (@s2, @ap, '2022-01-01', 'TEST A6', 'Approach', 'Minor', 'A6TEST Y');
INSERT INTO dbo.Incident(aircraft_id, airport_id, incident_date, location, phase_of_flight, severity, description, is_deleted, deleted_at)
  VALUES (@s2, @ap, '2022-02-02', 'TEST A6', 'Approach', 'Minor', 'A6TEST Z deleted', 1, SYSDATETIME());
INSERT INTO dbo.Incident_Cause(incident_id, cause_id, is_primary)
  SELECT incident_id, @cause, 1 FROM dbo.Incident WHERE description IN ('A6TEST X', 'A6TEST Y', 'A6TEST Z deleted');
GO

/* ===================== TESTS ===================== */
-- 1 scalar function returns a number between 0 and 100 for a real aircraft
DECLARE @s DECIMAL(5,1) = dbo.fn_AircraftRiskScore(1);
INSERT #r VALUES (1, 'fn_AircraftRiskScore(1) is between 0 and 100', CASE WHEN @s BETWEEN 0 AND 100 THEN 'PASS' ELSE 'FAIL' END, CONCAT('score=', @s));

-- 2 exact formula: 65.0 (window of 10 years, soft-deleted ignored)
DECLARE @r1 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-R1');
DECLARE @s2 DECIMAL(5,1) = dbo.fn_AircraftRiskScore(@r1);
INSERT #r VALUES (2, 'Score formula gives exactly 65.0 on the test aircraft', CASE WHEN @s2 = 65.0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('score=', @s2, ' expected=65.0'));

-- 3 cap at 100
DECLARE @r2 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-R2');
DECLARE @s3 DECIMAL(5,1) = dbo.fn_AircraftRiskScore(@r2);
INSERT #r VALUES (3, 'Score is capped at 100', CASE WHEN @s3 = 100.0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('score=', @s3));

-- 4 clean new aircraft scores 0
DECLARE @r3 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-R3');
DECLARE @s4 DECIMAL(5,1) = dbo.fn_AircraftRiskScore(@r3);
INSERT #r VALUES (4, 'New aircraft with no incidents and no maintenance scores 0.0', CASE WHEN @s4 = 0.0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('score=', @s4));

-- 5 overdue is judged on the LATEST maintenance record
DECLARE @r4 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-R4');
DECLARE @s5 DECIMAL(5,1) = dbo.fn_AircraftRiskScore(@r4);
INSERT #r VALUES (5, 'Old overdue record does not count when the latest one is not overdue', CASE WHEN @s5 = 0.0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('score=', @s5));

-- 6 unknown aircraft gives NULL
DECLARE @s6 DECIMAL(5,1) = dbo.fn_AircraftRiskScore(-1);
INSERT #r VALUES (6, 'Unknown aircraft returns NULL', CASE WHEN @s6 IS NULL THEN 'PASS' ELSE 'FAIL' END, CONCAT('score=', @s6));

-- 7 breakdown parts: 44.0 + 1.0 + 10.0 + 10.0
DECLARE @r1b INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A6-R1');
INSERT #r
SELECT 7, 'fn_AircraftRiskBreakdown parts are 44 / 1 / 10 / 10',
       CASE WHEN incident_points = 44.0 AND fatality_points = 1.0 AND age_points = 10.0 AND overdue_points = 10.0 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT(incident_points, ' / ', fatality_points, ' / ', age_points, ' / ', overdue_points)
FROM dbo.fn_AircraftRiskBreakdown(@r1b);

-- 8 fn_IncidentsByAirline: right count, no soft-deleted rows
DECLARE @al INT = (SELECT airline_id FROM dbo.Airline WHERE name = 'TEST A6 Air');
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.fn_IncidentsByAirline(@al));
DECLARE @real INT = (SELECT COUNT(*) FROM dbo.Incident i JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
                      WHERE a.airline_id = @al AND i.is_deleted = 0);
DECLARE @del INT = (SELECT COUNT(*) FROM dbo.fn_IncidentsByAirline(@al) f JOIN dbo.Incident i ON i.incident_id = f.incident_id WHERE i.is_deleted = 1);
INSERT #r VALUES (8, 'fn_IncidentsByAirline counts only live incidents of that airline',
   CASE WHEN @n = @real AND @n > 0 AND @del = 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('function=', @n, ' real=', @real, ' deleted rows=', @del));

-- 9 CROSS APPLY report: per-airline counts add up to all live incidents
DECLARE @sum INT = (SELECT SUM(x.n) FROM dbo.Airline al CROSS APPLY (SELECT COUNT(*) AS n FROM dbo.fn_IncidentsByAirline(al.airline_id)) x);
DECLARE @all INT = (SELECT COUNT(*) FROM dbo.Incident WHERE is_deleted = 0);
INSERT #r VALUES (9, 'CROSS APPLY over all airlines adds up to all live incidents', CASE WHEN @sum = @all THEN 'PASS' ELSE 'FAIL' END, CONCAT('sum=', @sum, ' all=', @all));

-- 10 similar incidents: Y is the best match with score 7 and all four reasons
DECLARE @x INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A6TEST X');
DECLARE @y INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A6TEST Y');
INSERT #r
SELECT 10, 'fn_SimilarIncidents: best match scores 7 with 4 reasons',
       CASE WHEN incident_id = @y AND score = 7 AND reasons = 'same cause, same aircraft type, same phase, same airport' THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('id=', incident_id, ' score=', score, ' reasons=', reasons)
FROM dbo.fn_SimilarIncidents(@x, 1);

-- 11 the incident itself and the soft-deleted look-alike are never returned
DECLARE @z INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A6TEST Z deleted');
DECLARE @cnt INT = (SELECT COUNT(*) FROM dbo.fn_SimilarIncidents(@x, 50));
DECLARE @bad INT = (SELECT COUNT(*) FROM dbo.fn_SimilarIncidents(@x, 50) WHERE incident_id IN (@x, @z));
INSERT #r VALUES (11, 'fn_SimilarIncidents excludes itself and soft-deleted rows', CASE WHEN @cnt > 0 AND @bad = 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rows=', @cnt, ' bad=', @bad));

-- 12 unknown incident gives no rows
DECLARE @e INT = (SELECT COUNT(*) FROM dbo.fn_SimilarIncidents(-1, 5));
INSERT #r VALUES (12, 'fn_SimilarIncidents on an unknown incident returns 0 rows', CASE WHEN @e = 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rows=', @e));

-- 13 the @top limit works on real data (incident 10)
DECLARE @t INT = (SELECT COUNT(*) FROM dbo.fn_SimilarIncidents(10, 3));
DECLARE @self INT = (SELECT COUNT(*) FROM dbo.fn_SimilarIncidents(10, 3) WHERE incident_id = 10);
INSERT #r VALUES (13, 'fn_SimilarIncidents(10, 3) returns exactly 3 rows, not incident 10', CASE WHEN @t = 3 AND @self = 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rows=', @t));
GO

-- 14 v_aircraft_risk keeps the UNCAPPED total next to the capped score (cap test aircraft: 480 + 6 + 10 = 496, score 100)
DECLARE @raw DECIMAL(9,1), @cap DECIMAL(5,1);
SELECT @raw = raw_total, @cap = risk_score FROM dbo.v_aircraft_risk WHERE registration_no = 'TEST-A6-R2';
INSERT #r VALUES (14, 'v_aircraft_risk: raw_total 496.0, risk_score capped at 100.0', CASE WHEN @raw = 496.0 AND @cap = 100.0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('raw=', @raw, ' score=', @cap));

-- 15 the fleet percentile spreads the real aircraft out (many different values, all three colour bands used)
DECLARE @d INT, @b INT;
SELECT @d = COUNT(DISTINCT risk_percentile), @b = COUNT(DISTINCT risk_band) FROM dbo.v_aircraft_risk WHERE registration_no NOT LIKE 'TEST-A6-%';
INSERT #r VALUES (15, 'Percentile and bands spread the fleet out (no flat line)', CASE WHEN @d >= 20 AND @b = 3 THEN 'PASS' ELSE 'FAIL' END, CONCAT('distinct percentiles=', @d, ' bands=', @b));
GO

SELECT no, test, result, detail FROM #r ORDER BY no;
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS passed, COUNT(*) AS total FROM #r;
GO

/* ---- the three checks from the task book (look at the output yourself) ---- */
SELECT dbo.fn_AircraftRiskScore(1) AS risk_score_of_aircraft_1;
SELECT * FROM dbo.fn_SimilarIncidents(10, 5);
-- report with CROSS APPLY: incidents and fatalities per airline, worst first
SELECT al.name AS airline, x.incidents, x.fatalities
FROM dbo.Airline al
CROSS APPLY (SELECT COUNT(*) AS incidents, COALESCE(SUM(f.fatalities), 0) AS fatalities
             FROM dbo.fn_IncidentsByAirline(al.airline_id) f) x
ORDER BY x.fatalities DESC;
-- top 10 riskiest aircraft (feeds the dashboard in A13): now ranked on the uncapped total, so no flat line of 100.0
SELECT TOP 10 registration_no, airline, risk_score, raw_total, risk_percentile, risk_band, risk_rank
FROM dbo.v_aircraft_risk
WHERE registration_no NOT LIKE 'TEST-A6-%'
ORDER BY raw_total DESC;
GO

/* ---- cleanup ---- */
DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;   -- real delete for test rows (the trigger would only mark them deleted)
DELETE FROM dbo.Audit_Log WHERE table_name = 'Incident' AND record_id IN
  (SELECT incident_id FROM dbo.Incident WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A6-%'));
DELETE FROM dbo.Incident WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A6-%');
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM dbo.Maintenance_Record WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A6-%');
DELETE FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A6-%';
DELETE FROM dbo.Airport WHERE name LIKE 'TEST A6%';
DELETE FROM dbo.Aircraft_Type WHERE manufacturer = 'TESTMAKER6';
DELETE FROM dbo.Airline WHERE name LIKE 'TEST A6%';
DROP TABLE #r;
GO
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;   -- safety net: make sure it is on
GO
