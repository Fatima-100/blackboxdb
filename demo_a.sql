/* demo_a.sql - Member A test blocks.  Run the WHOLE file (F5) after 00_create_db.sql + schema_incident.sql.
   A1 section: 15 tests. Every test inserts one row into #results (PASS or FAIL + the real error message).
   The last SELECT shows the table of results. All test rows are named 'TEST...' and are removed at the start and end. */
USE blackboxdb;
GO
IF OBJECT_ID('tempdb..#results') IS NOT NULL DROP TABLE #results;
CREATE TABLE #results (test VARCHAR(6), result VARCHAR(4), message VARCHAR(400));
GO

/* ---- cleanup of old test rows (safe to run many times) ---- */
DELETE FROM Audit_Log WHERE table_name = 'Incident' AND record_id IN
  (SELECT incident_id FROM Incident WHERE aircraft_id IN (SELECT aircraft_id FROM Aircraft WHERE registration_no LIKE 'TEST-%'));
DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;   -- real delete for test rows (needs A7 installed; if A7 is not installed yet, comment these two lines)
DELETE FROM Incident WHERE aircraft_id IN (SELECT aircraft_id FROM Aircraft WHERE registration_no LIKE 'TEST-%');
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM Flight WHERE aircraft_id IN (SELECT aircraft_id FROM Aircraft WHERE registration_no LIKE 'TEST-%');
DELETE FROM Maintenance_Record WHERE aircraft_id IN (SELECT aircraft_id FROM Aircraft WHERE registration_no LIKE 'TEST-%');
DELETE FROM Aircraft WHERE registration_no LIKE 'TEST-%';
DELETE FROM Airport WHERE name LIKE 'TEST%';
DELETE FROM Aircraft_Type WHERE manufacturer = 'TESTMAKER';
DELETE FROM Airline WHERE name LIKE 'TEST%';
GO

/* ---- fixtures: one airline, one aircraft (built 2010), two airports, one incident ---- */
INSERT INTO Airline(name, country, iata_code) VALUES ('TEST Air', 'Testland', 'TT');
INSERT INTO Aircraft_Type(manufacturer, model, category_id)
  SELECT 'TESTMAKER', 'TESTMODEL', category_id FROM Aircraft_Category WHERE category_name = 'Light';
INSERT INTO Aircraft(registration_no, airline_id, type_id, year_built)
  SELECT 'TEST-001', (SELECT airline_id FROM Airline WHERE name = 'TEST Air'),
         (SELECT type_id FROM Aircraft_Type WHERE model = 'TESTMODEL'), 2010;
INSERT INTO Airport(iata_code, icao_code, name, city, country, latitude, longitude) VALUES
  ('TS1', 'TEST', 'TEST Airport 1', 'Testville', 'Testland', 31.5, 74.3),
  ('TS2', 'TESU', 'TEST Airport 2', 'Testburg',  'Testland', 25.2, 55.3);
INSERT INTO Incident(aircraft_id, incident_date, location, phase_of_flight, severity)
  SELECT aircraft_id, '2020-01-01', 'TEST location', 'Cruise', 'Minor' FROM Aircraft WHERE registration_no = 'TEST-001';
GO

/* ===================== 8 REQUIRED BAD-INSERT TESTS (each must FAIL with the right constraint) ===================== */

-- T1: latitude 120 is rejected (ck_airport_lat)
BEGIN TRY
  INSERT INTO Airport(name, country, latitude, longitude) VALUES ('TEST bad lat', 'Testland', 120, 10);
  INSERT INTO #results VALUES ('T1', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T1', CASE WHEN ERROR_MESSAGE() LIKE '%ck_airport_lat%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T2: longitude 200 is rejected (ck_airport_lon)
BEGIN TRY
  INSERT INTO Airport(name, country, latitude, longitude) VALUES ('TEST bad lon', 'Testland', 10, 200);
  INSERT INTO #results VALUES ('T2', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T2', CASE WHEN ERROR_MESSAGE() LIKE '%ck_airport_lon%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T3: aircraft built in 1800 is rejected (ck_aircraft_year)
BEGIN TRY
  INSERT INTO Aircraft(registration_no, airline_id, type_id, year_built)
    SELECT 'TEST-002', (SELECT airline_id FROM Airline WHERE name = 'TEST Air'),
           (SELECT type_id FROM Aircraft_Type WHERE model = 'TESTMODEL'), 1800;
  INSERT INTO #results VALUES ('T3', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T3', CASE WHEN ERROR_MESSAGE() LIKE '%ck_aircraft_year%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T4: aircraft status 'Broken' is rejected (ck_aircraft_status)
BEGIN TRY
  INSERT INTO Aircraft(registration_no, airline_id, type_id, year_built, status)
    SELECT 'TEST-003', (SELECT airline_id FROM Airline WHERE name = 'TEST Air'),
           (SELECT type_id FROM Aircraft_Type WHERE model = 'TESTMODEL'), 2015, 'Broken';
  INSERT INTO #results VALUES ('T4', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T4', CASE WHEN ERROR_MESSAGE() LIKE '%ck_aircraft_status%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T5: flight with the same origin and destination is rejected (ck_flight_route)
BEGIN TRY
  INSERT INTO Flight(flight_no, airline_id, aircraft_id, origin_airport_id, dest_airport_id, flight_date)
    SELECT 'TT100', ac.airline_id, ac.aircraft_id, ap.airport_id, ap.airport_id, '2020-01-01'
    FROM Aircraft ac, Airport ap WHERE ac.registration_no = 'TEST-001' AND ap.name = 'TEST Airport 1';
  INSERT INTO #results VALUES ('T5', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T5', CASE WHEN ERROR_MESSAGE() LIKE '%ck_flight_route%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T6: flight with negative passengers is rejected (ck_flight_pax)
BEGIN TRY
  INSERT INTO Flight(flight_no, airline_id, aircraft_id, origin_airport_id, dest_airport_id, flight_date, passengers_on_board)
    SELECT 'TT101', ac.airline_id, ac.aircraft_id,
           (SELECT airport_id FROM Airport WHERE name = 'TEST Airport 1'),
           (SELECT airport_id FROM Airport WHERE name = 'TEST Airport 2'), '2020-01-01', -5
    FROM Aircraft ac WHERE ac.registration_no = 'TEST-001';
  INSERT INTO #results VALUES ('T6', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T6', CASE WHEN ERROR_MESSAGE() LIKE '%ck_flight_pax%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T7: next maintenance due BEFORE the maintenance date is rejected (ck_maint_due)
BEGIN TRY
  INSERT INTO Maintenance_Record(aircraft_id, maint_date, maint_type, next_due_date)
    SELECT aircraft_id, '2024-05-01', 'Routine', '2024-01-01' FROM Aircraft WHERE registration_no = 'TEST-001';
  INSERT INTO #results VALUES ('T7', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T7', CASE WHEN ERROR_MESSAGE() LIKE '%ck_maint_due%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T8: incident with negative passengers is rejected (ck_incident_pax)
BEGIN TRY
  INSERT INTO Incident(aircraft_id, incident_date, location, phase_of_flight, severity, passengers_on_board)
    SELECT aircraft_id, '2021-02-02', 'TEST location', 'Taxi', 'Minor', -5 FROM Aircraft WHERE registration_no = 'TEST-001';
  INSERT INTO #results VALUES ('T8', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T8', CASE WHEN ERROR_MESSAGE() LIKE '%ck_incident_pax%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO

/* ===================== EXTRA TESTS: filtered indexes, unique rule, triggers ===================== */

-- T9: TWO airlines with NO iata_code are accepted (this was the one-NULL bug; must PASS = inserted)
BEGIN TRY
  INSERT INTO Airline(name, country, iata_code) VALUES ('TEST Nocode 1', 'Testland', NULL), ('TEST Nocode 2', 'Testland', NULL);
  INSERT INTO #results VALUES ('T9', 'PASS', 'two airlines without IATA code were inserted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T9', 'FAIL', ERROR_MESSAGE();
END CATCH
GO
-- T10: a duplicate airline iata_code is still rejected (ux_airline_iata)
BEGIN TRY
  INSERT INTO Airline(name, country, iata_code) VALUES ('TEST Dup', 'Testland', 'TT');
  INSERT INTO #results VALUES ('T10', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T10', CASE WHEN ERROR_MESSAGE() LIKE '%ux_airline_iata%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T11: a duplicate airport iata_code is rejected (ux_airport_iata)
BEGIN TRY
  INSERT INTO Airport(iata_code, name, country, latitude, longitude) VALUES ('TS1', 'TEST Dup airport', 'Testland', 10, 10);
  INSERT INTO #results VALUES ('T11', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T11', CASE WHEN ERROR_MESSAGE() LIKE '%ux_airport_iata%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T12: incident dated in the future is rejected by the trigger (error 50001)
BEGIN TRY
  INSERT INTO Incident(aircraft_id, incident_date, location, phase_of_flight, severity)
    SELECT aircraft_id, DATEADD(day, 5, CAST(GETDATE() AS DATE)), 'TEST location', 'Landing', 'Minor'
    FROM Aircraft WHERE registration_no = 'TEST-001';
  INSERT INTO #results VALUES ('T12', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T12', CASE WHEN ERROR_NUMBER() = 50001 THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T13: incident dated before the aircraft was built (2010) is rejected by the trigger (error 50006)
BEGIN TRY
  INSERT INTO Incident(aircraft_id, incident_date, location, phase_of_flight, severity)
    SELECT aircraft_id, '2005-06-01', 'TEST location', 'Approach', 'Minor' FROM Aircraft WHERE registration_no = 'TEST-001';
  INSERT INTO #results VALUES ('T13', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T13', CASE WHEN ERROR_NUMBER() = 50006 THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T14: same aircraft + date + phase twice is rejected (uq_incident_event)
BEGIN TRY
  INSERT INTO Incident(aircraft_id, incident_date, location, phase_of_flight, severity)
    SELECT aircraft_id, '2020-01-01', 'TEST duplicate', 'Cruise', 'Minor' FROM Aircraft WHERE registration_no = 'TEST-001';
  INSERT INTO #results VALUES ('T14', 'FAIL', 'bad row was accepted');
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T14', CASE WHEN ERROR_MESSAGE() LIKE '%uq_incident_event%' THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH
GO
-- T15: changing the status writes an Audit_Log v2 row (column_name = status, old and new value)
BEGIN TRY
  UPDATE Incident SET status = 'Closed'
   WHERE aircraft_id = (SELECT aircraft_id FROM Aircraft WHERE registration_no = 'TEST-001') AND incident_date = '2020-01-01';
  INSERT INTO #results
  SELECT 'T15', CASE WHEN EXISTS (
           SELECT 1 FROM Audit_Log al JOIN Incident i ON i.incident_id = al.record_id
           WHERE al.table_name = 'Incident' AND al.column_name = 'status' AND al.action_type = 'UPDATE'
             AND al.old_value = 'Open' AND al.new_value = 'Closed'
             AND i.aircraft_id = (SELECT aircraft_id FROM Aircraft WHERE registration_no = 'TEST-001'))
         THEN 'PASS' ELSE 'FAIL' END, 'audit row Open -> Closed expected';
END TRY
BEGIN CATCH
  INSERT INTO #results SELECT 'T15', 'FAIL', ERROR_MESSAGE();
END CATCH
GO

/* ---- show the results, then clean up the test rows ---- */
SELECT test, result, message FROM #results ORDER BY CAST(SUBSTRING(test, 2, 3) AS INT);
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS passed, COUNT(*) AS total FROM #results;
GO
DELETE FROM Audit_Log WHERE table_name = 'Incident' AND record_id IN
  (SELECT incident_id FROM Incident WHERE aircraft_id IN (SELECT aircraft_id FROM Aircraft WHERE registration_no LIKE 'TEST-%'));
DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;   -- real delete for test rows (needs A7 installed; if A7 is not installed yet, comment these two lines)
DELETE FROM Incident WHERE aircraft_id IN (SELECT aircraft_id FROM Aircraft WHERE registration_no LIKE 'TEST-%');
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM Flight WHERE aircraft_id IN (SELECT aircraft_id FROM Aircraft WHERE registration_no LIKE 'TEST-%');
DELETE FROM Maintenance_Record WHERE aircraft_id IN (SELECT aircraft_id FROM Aircraft WHERE registration_no LIKE 'TEST-%');
DELETE FROM Aircraft WHERE registration_no LIKE 'TEST-%';
DELETE FROM Airport WHERE name LIKE 'TEST%';
DELETE FROM Aircraft_Type WHERE manufacturer = 'TESTMAKER';
DELETE FROM Airline WHERE name LIKE 'TEST%';
GO
