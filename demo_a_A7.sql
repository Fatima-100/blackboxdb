/* demo_a_A7.sql - tests for the A7 triggers. Run after objects_a_A7.sql AND objects_a_A7_view.sql. Expect 14 PASS.
   Test rows are named 'TEST-A7-...' / 'TEST A7 ...'. They are removed at the start and end.
   Real deletes are impossible while trg_incident_softdelete is on, so the cleanup DISABLES that trigger for a moment and
   enables it again straight after (and once more at the very end of the script). */
USE blackboxdb;
GO
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (no INT, test VARCHAR(90), result VARCHAR(4), detail VARCHAR(250));
GO
/* ---- cleanup of old test rows ---- */
DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM dbo.Audit_Log WHERE table_name = 'Incident' AND record_id IN
  (SELECT incident_id FROM dbo.Incident WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A7-%'));
DELETE FROM dbo.Incident WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A7-%');
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM dbo.Crew_Member WHERE name LIKE 'TEST A7%';
DELETE FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A7-%';
DELETE FROM dbo.Aircraft_Type WHERE manufacturer = 'TESTMAKER7';
DELETE FROM dbo.Airline WHERE name LIKE 'TEST A7%';
GO
/* ---- fixtures ---- */
INSERT INTO dbo.Airline(name, country) VALUES ('TEST A7 Air', 'Testland');
INSERT INTO dbo.Aircraft_Type(manufacturer, model, category_id) SELECT 'TESTMAKER7', 'TESTMODEL7', MIN(category_id) FROM dbo.Aircraft_Category;
INSERT INTO dbo.Aircraft(registration_no, airline_id, type_id, year_built)
  SELECT v.reg, (SELECT airline_id FROM dbo.Airline WHERE name = 'TEST A7 Air'), (SELECT type_id FROM dbo.Aircraft_Type WHERE model = 'TESTMODEL7'), 2010
  FROM (VALUES ('TEST-A7-1'), ('TEST-A7-2'), ('TEST-A7-3')) v(reg);
INSERT INTO dbo.Crew_Member(name, role, license_no) VALUES
  ('TEST A7 crew 1', 'Pilot', 'TESTA7-L1'), ('TEST A7 crew 2', 'Co-pilot', 'TESTA7-L2');

DECLARE @a1 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A7-1');
-- I1 base incident, I2..I4 used for multi-row tests, J for the crew rule (1 fatality)
INSERT INTO dbo.Incident(aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, description) VALUES
  (@a1, '2021-03-01', 'TEST A7 place', 'Cruise',  'Minor', 0, 'A7TEST base'),
  (@a1, '2021-04-01', 'TEST A7 place', 'Taxi',    'Minor', 0, 'A7TEST multi'),
  (@a1, '2021-05-01', 'TEST A7 place', 'Takeoff', 'Minor', 0, 'A7TEST multi'),
  (@a1, '2021-06-01', 'TEST A7 place', 'Landing', 'Minor', 0, 'A7TEST multi'),
  (@a1, '2021-07-01', 'TEST A7 place', 'Descent', 'Fatal', 1, 'A7TEST crew rule');
GO

/* ===================== TESTS ===================== */
-- 1 INSERT writes exactly one audit row (action INSERT)
DECLARE @i1 INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST base');
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE table_name = 'Incident' AND record_id = @i1 AND action_type = 'INSERT');
INSERT #r VALUES (1, 'Insert writes one INSERT audit row', CASE WHEN @n = 1 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rows=', @n));
GO
-- 2 changing severity writes exactly one audit row with old and new value
DECLARE @i1 INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST base');
DECLARE @before INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE record_id = @i1 AND action_type = 'UPDATE');
UPDATE dbo.Incident SET severity = 'Serious' WHERE incident_id = @i1;
DECLARE @new INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE record_id = @i1 AND action_type = 'UPDATE') - @before;
DECLARE @ok INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE record_id = @i1 AND column_name = 'severity' AND old_value = 'Minor' AND new_value = 'Serious');
INSERT #r VALUES (2, 'Severity change writes one audit row (Minor -> Serious)', CASE WHEN @new = 1 AND @ok = 1 THEN 'PASS' ELSE 'FAIL' END, CONCAT('new rows=', @new));
GO
-- 3 changing two columns in one UPDATE writes two audit rows
DECLARE @i1 INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST base');
DECLARE @before INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE record_id = @i1 AND action_type = 'UPDATE');
UPDATE dbo.Incident SET location = 'TEST A7 new place', injuries = 4 WHERE incident_id = @i1;
DECLARE @new INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE record_id = @i1 AND action_type = 'UPDATE') - @before;
INSERT #r VALUES (3, 'Two changed columns write two audit rows', CASE WHEN @new = 2 THEN 'PASS' ELSE 'FAIL' END, CONCAT('new rows=', @new));
GO
-- 4 changing a column that is not audited (description) writes nothing
DECLARE @i1 INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST base');
DECLARE @before INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE record_id = @i1);
UPDATE dbo.Incident SET description = 'A7TEST base' + ' edited' WHERE incident_id = @i1;
DECLARE @new INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE record_id = @i1) - @before;
UPDATE dbo.Incident SET description = 'A7TEST base' WHERE incident_id = @i1;
INSERT #r VALUES (4, 'Changing a column that is not audited writes no audit row', CASE WHEN @new = 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('new rows=', @new));
GO
-- 5 one UPDATE on 3 incidents writes 3 audit rows (set-based)
DECLARE @before INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE action_type = 'UPDATE' AND column_name = 'severity'
                        AND record_id IN (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST multi'));
UPDATE dbo.Incident SET severity = 'Major' WHERE description = 'A7TEST multi';
DECLARE @new INT = (SELECT COUNT(*) FROM dbo.Audit_Log WHERE action_type = 'UPDATE' AND column_name = 'severity'
                     AND record_id IN (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST multi')) - @before;
INSERT #r VALUES (5, 'One UPDATE of 3 rows writes 3 audit rows', CASE WHEN @new = 3 THEN 'PASS' ELSE 'FAIL' END, CONCAT('new rows=', @new));
GO
-- 6 DELETE of 2 rows in one statement only marks them deleted
DECLARE @i1 INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST base');
DECLARE @i4 INT = (SELECT TOP 1 incident_id FROM dbo.Incident WHERE description = 'A7TEST multi' ORDER BY incident_id DESC);
DELETE FROM dbo.Incident WHERE incident_id IN (@i1, @i4);
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.Incident WHERE incident_id IN (@i1, @i4) AND is_deleted = 1 AND deleted_at IS NOT NULL);
INSERT #r VALUES (6, 'DELETE keeps the rows and sets is_deleted = 1 and deleted_at', CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rows still there and marked=', @n));
GO
-- 7 the soft delete is logged as action DELETE (0 -> 1), one row per incident
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.Audit_Log al JOIN dbo.Incident i ON i.incident_id = al.record_id
                   WHERE al.action_type = 'DELETE' AND al.column_name = 'is_deleted' AND al.old_value = '0' AND al.new_value = '1'
                     AND i.is_deleted = 1 AND i.description IN ('A7TEST base', 'A7TEST multi')
                     AND i.aircraft_id = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A7-1'));
INSERT #r VALUES (7, 'Soft delete writes DELETE audit rows (2 rows deleted = 2 audit rows)', CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END, CONCAT('audit rows=', @n));
GO
-- 8 two Fatal crew on an incident with 1 fatality is rejected (50101) and nothing is saved
DECLARE @j INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST crew rule');
DECLARE @err INT = NULL;
BEGIN TRY
  INSERT INTO dbo.Incident_Crew(incident_id, crew_id, role_on_flight, injury_status)
  SELECT @j, crew_id, 'Pilot', 'Fatal' FROM dbo.Crew_Member WHERE name LIKE 'TEST A7 crew%';
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.Incident_Crew WHERE incident_id = @j);
INSERT #r VALUES (8, '2 Fatal crew, 1 fatality: error 50101 and no crew saved', CASE WHEN @err = 50101 AND @n = 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=', @err, ' crew rows=', @n));
GO
-- 9 one Fatal crew (1 fatality) is accepted; the second crew member with None is accepted too
DECLARE @j INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST crew rule');
DECLARE @err NVARCHAR(300) = NULL;
BEGIN TRY
  INSERT INTO dbo.Incident_Crew(incident_id, crew_id, role_on_flight, injury_status)
  SELECT @j, crew_id, 'Pilot', CASE WHEN name LIKE '%crew 1' THEN 'Fatal' ELSE 'None' END FROM dbo.Crew_Member WHERE name LIKE 'TEST A7 crew%';
END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.Incident_Crew WHERE incident_id = @j);
INSERT #r VALUES (9, '1 Fatal crew with 1 fatality is accepted', CASE WHEN @err IS NULL AND @n = 2 THEN 'PASS' ELSE 'FAIL' END, COALESCE(@err, CONCAT('crew rows=', @n)));
GO
-- 10 UPDATE that makes a second crew member Fatal is rejected (50101)
DECLARE @j INT = (SELECT incident_id FROM dbo.Incident WHERE description = 'A7TEST crew rule');
DECLARE @err INT = NULL;
BEGIN TRY
  UPDATE dbo.Incident_Crew SET injury_status = 'Fatal' WHERE incident_id = @j;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT #r VALUES (10, 'UPDATE to a second Fatal crew is rejected with 50101', CASE WHEN @err = 50101 THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=', @err));
GO
-- 11 a Major incident grounds an Active aircraft; a Minor one does not
DECLARE @a2 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A7-2');
DECLARE @a3 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A7-3');
INSERT INTO dbo.Incident(aircraft_id, incident_date, location, phase_of_flight, severity, description) VALUES
  (@a2, '2022-01-01', 'TEST A7 place', 'Cruise', 'Major', 'A7TEST ground'),
  (@a3, '2022-01-01', 'TEST A7 place', 'Cruise', 'Minor', 'A7TEST noground');
DECLARE @s2 VARCHAR(10) = (SELECT status FROM dbo.Aircraft WHERE aircraft_id = @a2);
DECLARE @s3 VARCHAR(10) = (SELECT status FROM dbo.Aircraft WHERE aircraft_id = @a3);
INSERT #r VALUES (11, 'Major incident grounds its aircraft, Minor does not', CASE WHEN @s2 = 'Grounded' AND @s3 = 'Active' THEN 'PASS' ELSE 'FAIL' END, CONCAT('major aircraft=', @s2, ', minor aircraft=', @s3));
GO
-- 12 insert ONE row through the view: incident and primary cause are created
DECLARE @a1 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A7-1');
DECLARE @c1 INT = (SELECT MIN(cause_id) FROM dbo.Cause);
DECLARE @err NVARCHAR(300) = NULL;
BEGIN TRY
  INSERT INTO dbo.v_incident_full(aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, primary_cause_id)
  VALUES (@a1, '2022-02-01', 'TEST A7 view one', 'Cruise', 'Minor', 0, 0, @c1);
END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.Incident i JOIN dbo.Incident_Cause ic ON ic.incident_id = i.incident_id AND ic.is_primary = 1 AND ic.cause_id = @c1
                   WHERE i.location = 'TEST A7 view one');
INSERT #r VALUES (12, 'Insert through v_incident_full creates incident + primary cause', CASE WHEN @err IS NULL AND @n = 1 THEN 'PASS' ELSE 'FAIL' END, COALESCE(@err, CONCAT('rows=', @n)));
GO
-- 13 insert THREE rows in one statement through the view: each incident gets ITS OWN cause
DECLARE @a1 INT = (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no = 'TEST-A7-1');
DECLARE @c1 INT = (SELECT MIN(cause_id) FROM dbo.Cause);
DECLARE @c2 INT = (SELECT MIN(cause_id) FROM dbo.Cause WHERE cause_id > @c1);
DECLARE @err NVARCHAR(300) = NULL;
BEGIN TRY
  INSERT INTO dbo.v_incident_full(aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, primary_cause_id)
  VALUES (@a1, '2022-03-01', 'TEST A7 view 1', 'Cruise',  'Minor', 0, 0, @c1),
         (@a1, '2022-03-02', 'TEST A7 view 2', 'Taxi',    'Minor', 0, 0, @c2),
         (@a1, '2022-03-03', 'TEST A7 view 3', 'Landing', 'Minor', 0, 0, @c1);
END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
DECLARE @right INT = (SELECT COUNT(*) FROM dbo.Incident i JOIN dbo.Incident_Cause ic ON ic.incident_id = i.incident_id AND ic.is_primary = 1
                       WHERE (i.location = 'TEST A7 view 1' AND ic.cause_id = @c1) OR (i.location = 'TEST A7 view 2' AND ic.cause_id = @c2)
                          OR (i.location = 'TEST A7 view 3' AND ic.cause_id = @c1));
DECLARE @all INT = (SELECT COUNT(*) FROM dbo.Incident WHERE location LIKE 'TEST A7 view _');
INSERT #r VALUES (13, '3 rows through the view: 3 incidents, each with the right cause', CASE WHEN @err IS NULL AND @right = 3 AND @all = 3 THEN 'PASS' ELSE 'FAIL' END,
                  COALESCE(@err, CONCAT('incidents=', @all, ' correct causes=', @right)));
GO
-- 14 a soft-deleted incident is ignored by trg_incident_date (a future date on it does not raise 50001)
DECLARE @err INT = NULL;
BEGIN TRY
  UPDATE dbo.Incident SET incident_date = DATEADD(DAY, 30, CAST(GETDATE() AS DATE)) WHERE description = 'A7TEST base' AND is_deleted = 1;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT #r VALUES (14, 'Deleted incident is ignored by the date trigger', CASE WHEN @err IS NULL THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=', @err));
GO

SELECT no, test, result, detail FROM #r ORDER BY no;
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS passed, COUNT(*) AS total FROM #r;
GO
/* ---- look at the audit trail of the base incident yourself ---- */
SELECT al.log_id, al.action_type, al.column_name, al.old_value, al.new_value, al.changed_by
FROM dbo.Audit_Log al
WHERE al.table_name = 'Incident'
  AND al.record_id = (SELECT TOP 1 incident_id FROM dbo.Incident WHERE description = 'A7TEST base')
ORDER BY al.log_id;
GO

/* ---- cleanup ---- */
DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM dbo.Audit_Log WHERE table_name = 'Incident' AND record_id IN
  (SELECT incident_id FROM dbo.Incident WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A7-%'));
DELETE FROM dbo.Incident WHERE aircraft_id IN (SELECT aircraft_id FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A7-%');
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM dbo.Crew_Member WHERE name LIKE 'TEST A7%';
DELETE FROM dbo.Aircraft WHERE registration_no LIKE 'TEST-A7-%';
DELETE FROM dbo.Aircraft_Type WHERE manufacturer = 'TESTMAKER7';
DELETE FROM dbo.Airline WHERE name LIKE 'TEST A7%';
DROP TABLE #r;
GO
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;   -- safety net: make sure it is on
GO
