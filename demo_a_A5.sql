/* demo_a_A5.sql - checks for the 5 views. Run after views_a_A5.sql.
   Changes are made inside transactions that are rolled back. */
SET NOCOUNT ON;
SELECT TOP 5 * FROM dbo.v_incident_full ORDER BY incident_id;
SELECT TOP 5 * FROM dbo.v_fatal_incidents ORDER BY incident_id;
SELECT TOP 5 * FROM dbo.v_cause_trend ORDER BY incident_year DESC, rank_in_year;
SELECT TOP 5 * FROM dbo.v_incident_phase_stats WITH (NOEXPAND) ORDER BY n DESC;
SELECT TOP 5 * FROM dbo.v_incident_map ORDER BY incident_id;

IF OBJECT_ID('tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (no INT, test VARCHAR(80), result VARCHAR(4), detail VARCHAR(200));
DECLARE @id INT = (SELECT MIN(incident_id) FROM dbo.v_fatal_incidents), @n INT, @n2 INT, @err INT, @ac INT = (SELECT TOP 1 aircraft_id FROM dbo.Aircraft WHERE year_built <= 2015 ORDER BY aircraft_id);

-- 1 update through the view that keeps the row fatal: works
BEGIN TRAN;
BEGIN TRY
  UPDATE dbo.v_fatal_incidents SET injuries = injuries + 1 WHERE incident_id=@id;
  SET @n = @@ROWCOUNT;
END TRY BEGIN CATCH SET @n = -1; END CATCH
ROLLBACK;
INSERT #r VALUES (1,'UPDATE through v_fatal_incidents (stays Fatal) works', CASE WHEN @n=1 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rows=',@n));

-- 2 update that makes the row non-fatal: rejected by WITH CHECK OPTION
SET @err = NULL;
BEGIN TRAN;
BEGIN TRY UPDATE dbo.v_fatal_incidents SET severity='Minor' WHERE incident_id=@id; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
ROLLBACK;
INSERT #r VALUES (2,'UPDATE to Minor through v_fatal_incidents is rejected', CASE WHEN @err=550 THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=',@err,' (550 = check option)'));

-- 3 insert a non-fatal row through the view: rejected
SET @err = NULL;
BEGIN TRAN;
BEGIN TRY INSERT dbo.v_fatal_incidents (aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, description)
          VALUES (@ac, '2020-07-01', 'A5TEST', 'Cruise', 'Minor', 0, 0, 'A5TEST'); END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
ROLLBACK;
INSERT #r VALUES (3,'INSERT of a Minor row through v_fatal_incidents is rejected', CASE WHEN @err=550 THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=',@err));

-- 4 insert a fatal row through the view: works
SET @err = NULL;
BEGIN TRAN;
BEGIN TRY INSERT dbo.v_fatal_incidents (aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, description)
          VALUES (@ac, '2020-07-02', 'A5TEST', 'Cruise', 'Fatal', 1, 0, 'A5TEST'); SET @n = @@ROWCOUNT; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); SET @n = -1; END CATCH
ROLLBACK;
INSERT #r VALUES (4,'INSERT of a Fatal row through v_fatal_incidents works', CASE WHEN @n=1 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rows=',@n,' error=',@err));

-- 5 indexed view totals match the base table
SELECT @n = SUM(n), @n2 = SUM(fatalities) FROM dbo.v_incident_phase_stats WITH (NOEXPAND);
INSERT #r VALUES (5,'Indexed view totals equal the Incident table',
  CASE WHEN @n = (SELECT COUNT(*) FROM dbo.Incident WHERE is_deleted=0)
        AND @n2 = (SELECT SUM(fatalities) FROM dbo.Incident WHERE is_deleted=0) THEN 'PASS' ELSE 'FAIL' END, CONCAT('n=',@n,' fatalities=',@n2));

-- 6 map view only has rows with an airport
INSERT #r VALUES (6,'v_incident_map has exactly the incidents that have an airport',
  CASE WHEN (SELECT COUNT(*) FROM dbo.v_incident_map) = (SELECT COUNT(*) FROM dbo.Incident WHERE airport_id IS NOT NULL AND is_deleted=0) THEN 'PASS' ELSE 'FAIL' END, '');

SELECT * FROM #r ORDER BY no;
DROP TABLE #r;

/* Execution plan proof: in SSMS press Ctrl+M (Include Actual Execution Plan), then run both.
   The first plan scans the small stored view index; the second scans the whole Incident table. */
SET STATISTICS IO ON;
SELECT phase_of_flight, n, fatalities FROM dbo.v_incident_phase_stats WITH (NOEXPAND);
SELECT phase_of_flight, COUNT_BIG(*) AS n, SUM(fatalities) AS fatalities FROM dbo.Incident WHERE is_deleted=0 GROUP BY phase_of_flight;
SET STATISTICS IO OFF;
