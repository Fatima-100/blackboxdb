/* demo_a_A4.sql - tests for the 5 procedures. Run after objects_a_A4.sql.
   Expect 10 PASS in the grid. Test rows are tagged 'A4TEST' and removed at
   the end. The archive test runs inside a transaction that is rolled back,
   so your real data is not changed. */
      USE blackboxdb;
GO
SET NOCOUNT ON;
DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM dbo.Audit_Log WHERE table_name = 'Incident' AND record_id IN (SELECT incident_id FROM dbo.Incident WHERE description LIKE 'A4TEST%');
DELETE FROM dbo.Incident WHERE description LIKE 'A4TEST%';
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;   -- clean old runs
IF OBJECT_ID('tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (no INT, test VARCHAR(70), result VARCHAR(4), detail VARCHAR(200));

DECLARE @ac INT   = (SELECT TOP 1 aircraft_id FROM dbo.Aircraft WHERE year_built <= 2015 ORDER BY aircraft_id);
DECLARE @c1 INT   = (SELECT MIN(cause_id) FROM dbo.Cause);
DECLARE @c2 INT   = (SELECT MIN(cause_id) FROM dbo.Cause WHERE cause_id > @c1);
DECLARE @m1 INT   = (SELECT MIN(crew_id) FROM dbo.Crew_Member);
DECLARE @m2 INT   = (SELECT MIN(crew_id) FROM dbo.Crew_Member WHERE crew_id > @m1);
DECLARE @causes dbo.CauseList, @crew dbo.CrewList, @none dbo.CauseList, @two dbo.CauseList;
INSERT @causes VALUES (@c1, 1), (@c2, 0);
INSERT @two    VALUES (@c1, 1), (@c2, 1);
INSERT @crew   VALUES (@m1, 'Pilot', 'None'), (@m2, 'Co-pilot', 'None');
DECLARE @id INT, @rv BINARY(8), @rc INT, @tot INT, @msg NVARCHAR(300), @n INT, @n2 INT, @err INT;

-- 1 valid add
BEGIN TRY
  EXEC dbo.sp_AddIncident @aircraft_id=@ac, @incident_date='2020-06-01', @location='A4TEST place',
       @phase_of_flight='Cruise', @severity='Minor', @description='A4TEST ok',
       @causes=@causes, @crew=@crew, @condition_type='Clear', @visibility_km=10, @wind_speed_kmh=5, @temperature_c=20,
       @new_id=@id OUTPUT;
  SELECT @n = (SELECT COUNT(*) FROM dbo.Incident_Cause WHERE incident_id=@id),
         @n2 = (SELECT COUNT(*) FROM dbo.Weather_Condition WHERE incident_id=@id) * 10
             + (SELECT COUNT(*) FROM dbo.Incident_Crew WHERE incident_id=@id);
  INSERT #r VALUES (1,'AddIncident saves incident + 2 causes + weather + 2 crew',
     CASE WHEN @id IS NOT NULL AND @n=2 AND @n2=12 THEN 'PASS' ELSE 'FAIL' END, CONCAT('id=',@id,' causes=',@n,' w/crew=',@n2));
END TRY BEGIN CATCH INSERT #r VALUES (1,'AddIncident valid','FAIL',ERROR_MESSAGE()); END CATCH

-- 2 no cause
SET @err = NULL;
BEGIN TRY EXEC dbo.sp_AddIncident @aircraft_id=@ac,@incident_date='2020-06-02',@location='A4TEST',@phase_of_flight='Cruise',@severity='Minor',@description='A4TEST nocause',@causes=@none,@crew=@crew,@new_id=@id; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT #r VALUES (2,'No cause is rejected with 50110', CASE WHEN @err=50110 THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=',@err));

-- 3 two primaries
SET @err = NULL;
BEGIN TRY EXEC dbo.sp_AddIncident @aircraft_id=@ac,@incident_date='2020-06-03',@location='A4TEST',@phase_of_flight='Cruise',@severity='Minor',@description='A4TEST twoprimary',@causes=@two,@crew=@crew,@new_id=@id; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT #r VALUES (3,'Two primary causes rejected with 50111', CASE WHEN @err=50111 THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=',@err));

-- 4 failure half way rolls everything back (bad severity breaks the INSERT)
SET @err = NULL;
BEGIN TRY EXEC dbo.sp_AddIncident @aircraft_id=@ac,@incident_date='2020-06-04',@location='A4TEST',@phase_of_flight='Cruise',@severity='NotASeverity',@description='A4TEST rollback',@causes=@causes,@crew=@crew,@new_id=@id; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
SELECT @n = COUNT(*) FROM dbo.Incident WHERE description='A4TEST rollback';
INSERT #r VALUES (4,'Bad data: error raised and nothing saved', CASE WHEN @err IS NOT NULL AND @n=0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=',@err,' rows=',@n));

-- 5 and 6 update, then stale row_ver
SELECT @id = MAX(incident_id) FROM dbo.Incident WHERE description='A4TEST ok';
SELECT @rv = row_ver FROM dbo.Incident WHERE incident_id=@id;
EXEC @rc = dbo.sp_UpdateIncident @incident_id=@id,@aircraft_id=@ac,@incident_date='2020-06-01',@location='A4TEST place',
     @phase_of_flight='Cruise',@severity='Minor',@fatalities=0,@injuries=2,@description='A4TEST ok',@row_ver=@rv;
SELECT @n = injuries FROM dbo.Incident WHERE incident_id=@id;
INSERT #r VALUES (5,'UpdateIncident with current row_ver returns 0', CASE WHEN @rc=0 AND @n=2 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rc=',@rc,' injuries=',@n));
EXEC @rc = dbo.sp_UpdateIncident @incident_id=@id,@aircraft_id=@ac,@incident_date='2020-06-01',@location='A4TEST place',
     @phase_of_flight='Cruise',@severity='Minor',@fatalities=0,@injuries=3,@description='A4TEST ok',@row_ver=@rv;  -- old @rv
SELECT @n = injuries FROM dbo.Incident WHERE incident_id=@id;
INSERT #r VALUES (6,'UpdateIncident with OLD row_ver returns -1, no change', CASE WHEN @rc=-1 AND @n=2 THEN 'PASS' ELSE 'FAIL' END, CONCAT('rc=',@rc,' injuries=',@n));

-- 7 search: filter + paging + total
EXEC dbo.sp_SearchIncidents @severity='Fatal', @page=2, @page_size=5, @sort='severity', @total=@tot OUTPUT;
SELECT @n = COUNT(*) FROM dbo.Incident WHERE severity='Fatal' AND is_deleted=0 AND is_archived=0;
INSERT #r VALUES (7,'Search: total equals real count of Fatal incidents', CASE WHEN @tot=@n AND @tot>5 THEN 'PASS' ELSE 'FAIL' END, CONCAT('total=',@tot,' real=',@n));

-- 8 injection attempt in sort
SET @err = NULL;
BEGIN TRY EXEC dbo.sp_SearchIncidents @sort='date_desc; DROP TABLE Incident;--', @total=@tot OUTPUT; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT #r VALUES (8,'Bad sort rejected (50112), Incident table still exists', CASE WHEN @err=50112 AND OBJECT_ID('dbo.Incident') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, CONCAT('error=',@err));

-- 9 injection attempt in text: treated as plain text, finds 0 rows
CREATE TABLE #s (incident_id INT, incident_date DATE, location VARCHAR(255), phase_of_flight VARCHAR(30), severity VARCHAR(10),
                 fatalities INT, injuries INT, status VARCHAR(20), registration VARCHAR(20), airline_id INT, airline VARCHAR(100), model VARCHAR(100));
INSERT #s EXEC dbo.sp_SearchIncidents @text=N''' OR 1=1 --', @total=@tot OUTPUT;
INSERT #r VALUES (9,'Quote/OR 1=1 in text search is just text: 0 rows', CASE WHEN @tot=0 AND NOT EXISTS (SELECT 1 FROM #s) THEN 'PASS' ELSE 'FAIL' END, CONCAT('total=',@tot));
DROP TABLE #s;

-- 10 yearly stats adds up
CREATE TABLE #y (yr INT, Minor INT, Serious INT, Major INT, Fatal INT, Total INT);
INSERT #y EXEC dbo.sp_YearlyStats @from_year=1995, @to_year=2025;
SELECT @n = ISNULL(SUM(Total),0) FROM #y;
SELECT @n2 = COUNT(*) FROM dbo.Incident WHERE is_deleted=0 AND YEAR(incident_date) BETWEEN 1995 AND 2025;
INSERT #r VALUES (10,'YearlyStats: pivot total equals real count', CASE WHEN @n=@n2 AND @n>0 THEN 'PASS' ELSE 'FAIL' END, CONCAT('pivot=',@n,' real=',@n2));
DROP TABLE #y;

SELECT * FROM #r ORDER BY no;

-- 11 archive (inside a transaction, rolled back so nothing really changes)
BEGIN TRAN;
  DECLARE @eligible INT = (SELECT COUNT(*) FROM dbo.Incident WHERE is_archived=0 AND is_deleted=0 AND status='Closed'
                             AND incident_date < DATEADD(YEAR,-15,CAST(GETDATE() AS DATE)));
  DECLARE @moved INT;
  EXEC dbo.sp_ArchiveOldIncidents @older_than_years=15, @moved=@moved OUTPUT;
  DECLARE @left INT = (SELECT COUNT(*) FROM dbo.Incident WHERE is_archived=0 AND is_deleted=0 AND status='Closed'
                         AND incident_date < DATEADD(YEAR,-15,CAST(GETDATE() AS DATE)));
  SELECT 'Archive (rolled back after)' AS test, @eligible AS eligible_before, @moved AS moved, @left AS left_after,
         CASE WHEN @moved=@eligible AND @left=0 THEN 'PASS' ELSE 'FAIL' END AS result;
ROLLBACK;

DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DELETE FROM dbo.Audit_Log WHERE table_name = 'Incident' AND record_id IN (SELECT incident_id FROM dbo.Incident WHERE description LIKE 'A4TEST%');
DELETE FROM dbo.Incident WHERE description LIKE 'A4TEST%';
ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;
DROP TABLE #r;


