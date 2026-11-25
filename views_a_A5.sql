/* ============================================================================
   views_a_A5.sql  -  A5: Incident views (Member A)
   Run with your BlackBox database selected. Safe to run again.
   ============================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---- 1. v_incident_full -------------------------------------------------
   Multi-table view: base for the incident list. Deleted rows are hidden.
   Airport, Flight and the primary cause are LEFT joins (may be missing).
   Gets an INSTEAD OF trigger in A7.                                       */
CREATE OR ALTER VIEW dbo.v_incident_full AS
SELECT i.incident_id, i.incident_date, i.location, i.phase_of_flight,
       i.severity, i.fatalities, i.injuries, i.passengers_on_board,
       i.description, i.status, i.is_archived, i.created_at,
       a.aircraft_id, a.registration_no AS registration, a.year_built,
       al.airline_id, al.name AS airline,
       t.type_id, t.model, ac.category_name AS aircraft_category,
       ap.airport_id, ap.iata_code, ap.name AS airport_name,
       f.flight_id, f.flight_no,
       c.cause_id AS primary_cause_id, c.cause_name AS primary_cause
  FROM dbo.Incident i
  JOIN dbo.Aircraft          a  ON a.aircraft_id = i.aircraft_id
  JOIN dbo.Airline           al ON al.airline_id = a.airline_id
  JOIN dbo.Aircraft_Type     t  ON t.type_id     = a.type_id
  JOIN dbo.Aircraft_Category ac ON ac.category_id = t.category_id
  LEFT JOIN dbo.Airport         ap ON ap.airport_id = i.airport_id
  LEFT JOIN dbo.Flight          f  ON f.flight_id   = i.flight_id
  LEFT JOIN dbo.Incident_Cause  ic ON ic.incident_id = i.incident_id AND ic.is_primary = 1
  LEFT JOIN dbo.Cause           c  ON c.cause_id = ic.cause_id
 WHERE i.is_deleted = 0;
GO

/* ---- 2. v_fatal_incidents ----------------------------------------------
   WITH CHECK OPTION: an INSERT or UPDATE through the view that would make
   a row non-fatal (or deleted) is rejected, because the row would vanish
   from the view.                                                           */
CREATE OR ALTER VIEW dbo.v_fatal_incidents AS
SELECT incident_id, aircraft_id, incident_date, location, airport_id, flight_id,
       phase_of_flight, severity, fatalities, injuries, description, status,
       is_deleted, is_archived
  FROM dbo.Incident
 WHERE severity = 'Fatal' AND is_deleted = 0
WITH CHECK OPTION;
GO

/* ---- 3. v_cause_trend --------------------------------------------------
   Window functions inside a view: LAG gives the previous year that has data
   for the same cause (a gap year is skipped), DENSE_RANK ranks the causes
   inside each year (1 = most frequent).                                   */
CREATE OR ALTER VIEW dbo.v_cause_trend AS
WITH yearly AS (
    SELECT YEAR(i.incident_date) AS incident_year, c.cause_id, c.cause_name, COUNT(*) AS n
      FROM dbo.Incident i
      JOIN dbo.Incident_Cause ic ON ic.incident_id = i.incident_id
      JOIN dbo.Cause c           ON c.cause_id = ic.cause_id
     WHERE i.is_deleted = 0
     GROUP BY YEAR(i.incident_date), c.cause_id, c.cause_name
)
SELECT incident_year, cause_id, cause_name,
       n AS incident_count,
       LAG(n) OVER (PARTITION BY cause_id ORDER BY incident_year)       AS last_year_count,
       n - LAG(n) OVER (PARTITION BY cause_id ORDER BY incident_year)   AS change_from_last_year,
       DENSE_RANK() OVER (PARTITION BY incident_year ORDER BY n DESC)   AS rank_in_year
  FROM yearly;
GO

/* ---- 4. v_incident_phase_stats (INDEXED VIEW) -------------------------- */
-- An existing indexed view blocks CREATE OR ALTER, so drop it first.
IF OBJECT_ID(N'dbo.v_incident_phase_stats', N'V') IS NOT NULL
    DROP VIEW dbo.v_incident_phase_stats;
GO
CREATE VIEW dbo.v_incident_phase_stats
WITH SCHEMABINDING            -- locks the base table's columns; required for an index
AS
SELECT phase_of_flight,
       COUNT_BIG(*)                AS n,            -- required in an indexed view with GROUP BY
       SUM(ISNULL(fatalities, 0))  AS fatalities    -- no nullable expression inside SUM
  FROM dbo.Incident                                 -- two-part name is required
 WHERE is_deleted = 0
 GROUP BY phase_of_flight;
GO
CREATE UNIQUE CLUSTERED INDEX ix_v_incident_phase_stats
    ON dbo.v_incident_phase_stats (phase_of_flight);   -- this stores the result on disk
GO

/* ---- 5. v_incident_map -------------------------------------------------
   Data source for the map page (A12): only incidents with an airport.     */
CREATE OR ALTER VIEW dbo.v_incident_map AS
SELECT i.incident_id, ap.latitude, ap.longitude, i.severity, i.incident_date,
       al.name AS airline, i.fatalities, ap.iata_code, ap.name AS airport_name
  FROM dbo.Incident i
  JOIN dbo.Airport  ap ON ap.airport_id  = i.airport_id      -- INNER: airport required
  JOIN dbo.Aircraft a  ON a.aircraft_id  = i.aircraft_id
  JOIN dbo.Airline  al ON al.airline_id  = a.airline_id
 WHERE i.is_deleted = 0;
GO
PRINT 'A5 views created.';
