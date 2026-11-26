/* ============================================================================
   demo_a_A12.sql  -  A12 tests for v_incident_map and sp_GetMapPoints (Member A)
   Run with blackboxdb selected after objects_a_A12.sql.
   ============================================================================ */
USE blackboxdb;
GO
SET NOCOUNT ON;

DECLARE @results TABLE (test_name VARCHAR(80), status VARCHAR(10), detail VARCHAR(200));
DECLARE @tmp TABLE (
    incident_id   INT,
    latitude      FLOAT,
    longitude     FLOAT,
    severity      VARCHAR(10),
    incident_date DATE,
    airline_id    INT,
    airline       VARCHAR(100),
    registration  VARCHAR(20),
    fatalities    INT,
    iata_code     CHAR(3),
    airport_name  VARCHAR(120)
);

-- T1: All severities, full range -> should return rows (<= 10,000), all with non-null coords
DELETE FROM @tmp;
INSERT INTO @tmp
EXEC dbo.sp_GetMapPoints @from_year = 1995, @to_year = 2026,
                         @severity_list = 'Minor,Serious,Major,Fatal', @airline_id = NULL;
INSERT INTO @results
SELECT 'T1. All severities (1995-2026)',
       CASE WHEN COUNT(*) > 0 AND COUNT(*) <= 10000 AND MIN(latitude) IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
       'rows=' + CAST(COUNT(*) AS VARCHAR(10))
  FROM @tmp;

-- T2: Fatal only -> every returned row must have severity = 'Fatal'
DELETE FROM @tmp;
INSERT INTO @tmp
EXEC dbo.sp_GetMapPoints @from_year = 1995, @to_year = 2026,
                         @severity_list = 'Fatal', @airline_id = NULL;
INSERT INTO @results
SELECT 'T2. Fatal only via STRING_SPLIT',
       CASE WHEN COUNT(*) > 0 AND SUM(CASE WHEN severity <> 'Fatal' THEN 1 ELSE 0 END) = 0 THEN 'PASS' ELSE 'FAIL' END,
       'fatal_rows=' + CAST(COUNT(*) AS VARCHAR(10))
  FROM @tmp;

-- T3: Airline filter -> every returned row must match @airline_id = 1
DELETE FROM @tmp;
INSERT INTO @tmp
EXEC dbo.sp_GetMapPoints @from_year = 1995, @to_year = 2026,
                         @severity_list = 'Minor,Serious,Major,Fatal', @airline_id = 1;
INSERT INTO @results
SELECT 'T3. Single airline filter (airline_id=1)',
       CASE WHEN SUM(CASE WHEN airline_id <> 1 THEN 1 ELSE 0 END) = 0 THEN 'PASS' ELSE 'FAIL' END,
       'airline1_rows=' + CAST(COUNT(*) AS VARCHAR(10))
  FROM @tmp;

-- T4: Empty severity list -> 0 rows returned cleanly
DELETE FROM @tmp;
INSERT INTO @tmp
EXEC dbo.sp_GetMapPoints @from_year = 1995, @to_year = 2026,
                         @severity_list = '', @airline_id = NULL;
INSERT INTO @results
SELECT 'T4. Empty severity list returns 0 rows',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
       'rows=' + CAST(COUNT(*) AS VARCHAR(10))
  FROM @tmp;

-- T5: Invalid year range -> throws 50114
BEGIN TRY
    EXEC dbo.sp_GetMapPoints @from_year = 2025, @to_year = 2010;
    INSERT INTO @results VALUES ('T5. Invalid year range throws 50114', 'FAIL', 'did not throw');
END TRY
BEGIN CATCH
    INSERT INTO @results
    VALUES ('T5. Invalid year range throws 50114',
            CASE WHEN ERROR_NUMBER() = 50114 THEN 'PASS' ELSE 'FAIL' END,
            'error=' + CAST(ERROR_NUMBER() AS VARCHAR(10)));
END CATCH;

SELECT * FROM @results;
GO
