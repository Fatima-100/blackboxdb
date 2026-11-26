/* ==========================================================================
   demo_a_A3.sql - test block for A3 (append to demo_a.sql). Run AFTER objects_a.sql and the seed.
   Tests: fn_ImportParsed, sp_ValidateImport, sp_ImportIncidents. Cleans up all of its own rows.
   Expected: 8 PASS.
   ========================================================================== */
USE blackboxdb;
GO
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#a3') IS NOT NULL DROP TABLE #a3;
CREATE TABLE #a3 (test VARCHAR(10), result VARCHAR(4), message VARCHAR(300));

-- remove leftovers of an earlier failed run
DELETE FROM Incident WHERE description LIKE 'Imported from A3_TEST%';
DELETE FROM Aircraft WHERE registration_no LIKE 'ZZT-%';
DELETE FROM Aircraft_Type WHERE manufacturer = 'A3TestMake';
DELETE FROM Airline WHERE name = 'A3 Test Air';
DELETE FROM Audit_Log WHERE table_name = 'Import_Batch' AND new_value LIKE 'A3_TEST%';
DELETE FROM Import_Batch WHERE file_name = 'A3_TEST.csv';

DECLARE @b INT, @b2 INT, @imp INT, @skip INT, @err INT, @n INT, @n2 INT, @msg VARCHAR(300);

INSERT INTO Import_Batch (file_name, uploaded_by) VALUES ('A3_TEST.csv', 'tester');
SET @b = SCOPE_IDENTITY();
INSERT INTO Import_Staging (batch_id, row_no, raw_date, raw_location, raw_registration, raw_airline, raw_model, raw_phase, raw_fatalities, raw_injuries, raw_weather) VALUES
 (@b, 1, '2023-05-14', 'Test City', 'ZZT-001', 'A3 Test Air', 'A3TestMake X100', 'Approach',  '0',  '2', 'VMC'),   -- valid
 (@b, 2, '2023-06-01', 'Test City', 'ZZT-001', 'A3 Test Air', 'A3TestMake X100', 'Hovering',  '',   '',  'IMC'),   -- warning: unknown phase -> Cruise
 (@b, 3, '2023-02-30', 'Test City', 'ZZT-002', 'A3 Test Air', 'A3TestMake X100', 'Landing',   '0',  '0', 'VMC'),   -- error: impossible date
 (@b, 4, '2023-07-01', 'Test City', 'ZZT-003', 'A3 Test Air', 'A3TestMake X100', 'Landing',   '-1', '0', 'VMC'),   -- error: negative number
 (@b, 5, '2023-05-14', 'Test City', 'ZZT-001', 'A3 Test Air', 'A3TestMake X100', 'approach',  '0',  '0', 'VMC'),   -- duplicate of row 1 inside the file
 (@b, 6, '2999-01-01', 'Test City', 'ZZT-004', 'A3 Test Air', 'A3TestMake X100', 'Takeoff',   '0',  '0', 'VMC');   -- error: future date

-- T-A3-1: validation sets the right status on every row
EXEC dbo.sp_ValidateImport @b;
SELECT @n = COUNT(*) FROM Import_Staging WHERE batch_id = @b
   AND ((row_no = 1 AND row_status = 'Valid') OR (row_no = 2 AND row_status = 'Warning') OR (row_no = 3 AND row_status = 'Error')
     OR (row_no = 4 AND row_status = 'Error') OR (row_no = 5 AND row_status = 'Duplicate') OR (row_no = 6 AND row_status = 'Error'));
INSERT #a3 SELECT 'T-A3-1', CASE WHEN @n = 6 THEN 'PASS' ELSE 'FAIL' END, CONCAT(@n, ' of 6 rows have the expected status');

-- T-A3-2: error messages are readable
SELECT @msg = error_message FROM Import_Staging WHERE batch_id = @b AND row_no = 3;
INSERT #a3 SELECT 'T-A3-2', CASE WHEN @msg LIKE '%valid YYYY-MM-DD%' THEN 'PASS' ELSE 'FAIL' END, @msg;

-- T-A3-3: import adds 2 incidents, skips 1 duplicate, reports 3 errors
EXEC dbo.sp_ImportIncidents @b, @imp OUTPUT, @skip OUTPUT, @err OUTPUT;
INSERT #a3 SELECT 'T-A3-3', CASE WHEN @imp = 2 AND @skip = 1 AND @err = 3 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('imported ', @imp, ', skipped ', @skip, ', errors ', @err);

-- T-A3-4: MERGE created exactly one airline, one type and one aircraft; both incidents have weather
SELECT @n  = (SELECT COUNT(*) FROM Airline WHERE name = 'A3 Test Air') + (SELECT COUNT(*) FROM Aircraft_Type WHERE manufacturer = 'A3TestMake')
           + (SELECT COUNT(*) FROM Aircraft WHERE registration_no = 'ZZT-001');
SELECT @n2 = COUNT(*) FROM Incident i JOIN Weather_Condition w ON w.incident_id = i.incident_id WHERE i.description LIKE 'Imported from A3_TEST%';
INSERT #a3 SELECT 'T-A3-4', CASE WHEN @n = 3 AND @n2 = 2 THEN 'PASS' ELSE 'FAIL' END, CONCAT('new master rows ', @n, ' (expect 3), incidents with weather ', @n2, ' (expect 2)');

-- T-A3-5: derived values (injuries 2 -> Serious; unknown phase -> Cruise; imported incidents are Closed)
SELECT @n = COUNT(*) FROM Incident
WHERE description LIKE 'Imported from A3_TEST%' AND status = 'Closed'
  AND ((phase_of_flight = 'Approach' AND severity = 'Serious' AND injuries = 2) OR (phase_of_flight = 'Cruise' AND severity = 'Minor'));
INSERT #a3 SELECT 'T-A3-5', CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END, CONCAT(@n, ' of 2 incidents have the expected values');

-- T-A3-6: uploading the same rows again imports nothing (all valid rows become duplicates)
INSERT INTO Import_Batch (file_name, uploaded_by) VALUES ('A3_TEST.csv', 'tester');
SET @b2 = SCOPE_IDENTITY();
INSERT INTO Import_Staging (batch_id, row_no, raw_date, raw_location, raw_registration, raw_airline, raw_model, raw_phase, raw_fatalities, raw_injuries, raw_weather)
SELECT @b2, row_no, raw_date, raw_location, raw_registration, raw_airline, raw_model, raw_phase, raw_fatalities, raw_injuries, raw_weather
FROM Import_Staging WHERE batch_id = @b AND row_no IN (1, 2, 5, 3);
EXEC dbo.sp_ImportIncidents @b2, @imp OUTPUT, @skip OUTPUT, @err OUTPUT;
INSERT #a3 SELECT 'T-A3-6', CASE WHEN @imp = 0 AND @skip = 3 AND @err = 1 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('imported ', @imp, ', duplicates ', @skip, ', errors ', @err, ' (expect 0, 3, 1)');

-- T-A3-7: an unknown batch gives error 50101 and does not crash anything
BEGIN TRY
    EXEC dbo.sp_ImportIncidents 999999, @imp OUTPUT, @skip OUTPUT, @err OUTPUT;
    INSERT #a3 SELECT 'T-A3-7', 'FAIL', 'no error was raised';
END TRY
BEGIN CATCH
    INSERT #a3 SELECT 'T-A3-7', CASE WHEN ERROR_NUMBER() = 50101 THEN 'PASS' ELSE 'FAIL' END, ERROR_MESSAGE();
END CATCH;

-- T-A3-8: the import was written to the audit log
SELECT @n = COUNT(*) FROM Audit_Log WHERE table_name = 'Import_Batch' AND record_id IN (@b, @b2) AND new_value LIKE 'A3_TEST.csv%';
INSERT #a3 SELECT 'T-A3-8', CASE WHEN @n = 2 THEN 'PASS' ELSE 'FAIL' END, CONCAT(@n, ' audit rows (expect 2)');

-- clean up
DELETE FROM Incident WHERE description LIKE 'Imported from A3_TEST%';
DELETE FROM Aircraft WHERE registration_no LIKE 'ZZT-%';
DELETE FROM Aircraft_Type WHERE manufacturer = 'A3TestMake';
DELETE FROM Airline WHERE name = 'A3 Test Air';
DELETE FROM Audit_Log WHERE table_name = 'Import_Batch' AND new_value LIKE 'A3_TEST%';
DELETE FROM Import_Batch WHERE file_name = 'A3_TEST.csv';

SELECT * FROM #a3 ORDER BY test;
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS passed, COUNT(*) AS total FROM #a3;
DROP TABLE #a3;
GO




SELECT TOP 10 * FROM Incident WHERE description LIKE 'Imported from%';
SELECT TOP 5 * FROM Audit_Log ORDER BY log_id DESC;