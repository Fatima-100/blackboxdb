/* ============================================================================
   objects_a_A12.sql  -  A12: Map view view-update and stored procedure (Member A)
   Run with blackboxdb selected. Safe to run again (CREATE OR ALTER).
   Needs SQL Server 2016+ (STRING_SPLIT and CREATE OR ALTER).
   ============================================================================ */
USE blackboxdb;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- What: view of all non-deleted incidents that have an airport with coordinates.
-- Why:  feeds the /map page and sp_GetMapPoints so the map query stays simple and
--       excludes incidents without latitude/longitude.
-- Who:  Member A
CREATE OR ALTER VIEW dbo.v_incident_map AS
SELECT i.incident_id,
       ap.latitude,
       ap.longitude,
       i.severity,
       i.incident_date,
       al.airline_id,
       al.name           AS airline,
       a.registration_no AS registration,
       i.fatalities,
       ap.iata_code,
       ap.name           AS airport_name
  FROM dbo.Incident i
  JOIN dbo.Airport  ap ON ap.airport_id = i.airport_id
  JOIN dbo.Aircraft a  ON a.aircraft_id = i.aircraft_id
  JOIN dbo.Airline  al ON al.airline_id = a.airline_id
 WHERE i.is_deleted = 0;
GO

-- What: returns up to 10,000 map pins filtered by year range, comma-separated severities, and optional airline.
-- Why:  replaces dynamic IN-list building with STRING_SPLIT so the /map endpoint stays parameterized and fast.
-- Who:  Member A
CREATE OR ALTER PROCEDURE dbo.sp_GetMapPoints
    @from_year     INT          = 1995,
    @to_year       INT          = NULL,
    @severity_list VARCHAR(100) = 'Minor,Serious,Major,Fatal',
    @airline_id    INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @to_year IS NULL
        SET @to_year = YEAR(GETDATE());

    IF @from_year > @to_year
        THROW 50114, 'from_year must not be after to_year.', 1;

    SELECT TOP (10000)
           m.incident_id,
           CAST(m.latitude  AS FLOAT) AS latitude,
           CAST(m.longitude AS FLOAT) AS longitude,
           m.severity,
           m.incident_date,
           m.airline_id,
           m.airline,
           m.registration,
           m.fatalities,
           m.iata_code,
           m.airport_name
      FROM dbo.v_incident_map m
     WHERE YEAR(m.incident_date) BETWEEN @from_year AND @to_year
       AND m.severity IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@severity_list, ''), ','))
       AND (@airline_id IS NULL OR m.airline_id = @airline_id)
     ORDER BY m.incident_date DESC, m.incident_id DESC;
END;
GO

PRINT 'A12 map view and sp_GetMapPoints ready.';
GO
