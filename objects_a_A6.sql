/* ==========================================================================
   objects_a_A6.sql  -  BlackBox DB, Member A, task A6: functions
   Run with blackboxdb selected. Safe to run again (each function is dropped, then created).
   Needs SQL Server 2017 or newer (CONCAT_WS). Needs schema_incident.sql.
   Functions:  fn_AircraftRiskBreakdown (inline TVF, helper)   fn_AircraftRiskScore (scalar)
               fn_IncidentsByAirline (inline TVF)              fn_SimilarIncidents (inline TVF)
   View:       v_aircraft_risk (fleet ranking: uncapped total, capped score, percentile, band, rank)  [v2: fixes the flat 100.0 problem]
   ========================================================================== */
USE blackboxdb;
GO
DROP VIEW IF EXISTS dbo.v_aircraft_risk;
DROP FUNCTION IF EXISTS dbo.fn_AircraftRiskScore;
DROP FUNCTION IF EXISTS dbo.fn_AircraftRiskBreakdown;
DROP FUNCTION IF EXISTS dbo.fn_IncidentsByAirline;
DROP FUNCTION IF EXISTS dbo.fn_SimilarIncidents;
GO

/* ---------- fn_AircraftRiskBreakdown (helper) ---------- */
-- What: the four parts of an aircraft's risk score (incident points, fatality points, age points, overdue-maintenance points).
-- Why:  one place holds the formula, so the scalar score and the dashboard breakdown (task A13) can never disagree.
--       Inline table-valued, so the optimizer expands it into the calling query like a view.
-- Who:  Member A
-- Rules: only incidents of the LAST 10 YEARS count; soft-deleted incidents are ignored.
--        incident_points = (Minor 1, Serious 3, Major 6, Fatal 10 added up) * 4
--        fatality_points = 0.5 per fatality (same 10-year window)
--        age_points      = (this year - year_built) / 3   (0 when year_built is unknown or in the future)
--        overdue_points  = 10 when the next_due_date of the LATEST maintenance record is in the past, else 0
--        raw_total       = the four parts added up, NOT capped (the scalar function caps it at 100)
CREATE FUNCTION dbo.fn_AircraftRiskBreakdown (@aircraft_id INT)
RETURNS TABLE
AS
RETURN
  SELECT p.aircraft_id, p.incident_points, p.fatality_points, p.age_points, p.overdue_points,
         p.incident_points + p.fatality_points + p.age_points + p.overdue_points AS raw_total   -- NOT capped
  FROM (
    SELECT a.aircraft_id,
           CAST(inc.pts * 4 AS DECIMAL(9,1))   AS incident_points,
           CAST(inc.fat * 0.5 AS DECIMAL(9,1)) AS fatality_points,
           CAST(CASE WHEN a.year_built IS NOT NULL AND YEAR(GETDATE()) > a.year_built
                     THEN (YEAR(GETDATE()) - a.year_built) / 3.0 ELSE 0 END AS DECIMAL(9,1)) AS age_points,
           CAST(CASE WHEN m.next_due_date < CAST(GETDATE() AS DATE) THEN 10 ELSE 0 END AS DECIMAL(9,1)) AS overdue_points
    FROM dbo.Aircraft a
    OUTER APPLY (SELECT COALESCE(SUM(CASE i.severity WHEN 'Fatal' THEN 10 WHEN 'Major' THEN 6 WHEN 'Serious' THEN 3 ELSE 1 END), 0) AS pts,
                        COALESCE(SUM(i.fatalities), 0) AS fat
                 FROM dbo.Incident i
                 WHERE i.aircraft_id = a.aircraft_id AND i.is_deleted = 0
                   AND i.incident_date >= DATEADD(YEAR, -10, CAST(GETDATE() AS DATE))) inc
    OUTER APPLY (SELECT TOP 1 mr.next_due_date
                 FROM dbo.Maintenance_Record mr
                 WHERE mr.aircraft_id = a.aircraft_id
                 ORDER BY mr.maint_date DESC, mr.maint_id DESC) m
    WHERE a.aircraft_id = @aircraft_id
  ) p;
GO

/* ---------- fn_AircraftRiskScore ---------- */
-- What: risk score of one aircraft from 0 to 100 (NULL if the aircraft does not exist).
-- Why:  a scalar function can be used inside SELECT and WHERE, so reports can sort and filter by risk.
-- Who:  Member A
-- Formula: score = incident_points + fatality_points + age_points + overdue_points, capped at 100
--          = (sum of weights of incidents in the last 10 years, Minor 1 / Serious 3 / Major 6 / Fatal 10) * 4
--            + 0.5 per fatality + aircraft age / 3 + 10 if maintenance is overdue
-- Colour bands for the dashboard: 0 to 30 green, 31 to 60 amber, above 60 red.
CREATE FUNCTION dbo.fn_AircraftRiskScore (@aircraft_id INT)
RETURNS DECIMAL(5,1)
AS
BEGIN
  DECLARE @total DECIMAL(9,1);
  SELECT @total = raw_total FROM dbo.fn_AircraftRiskBreakdown(@aircraft_id);
  RETURN CAST(CASE WHEN @total > 100 THEN 100 ELSE @total END AS DECIMAL(5,1));
END;
GO

/* ---------- fn_IncidentsByAirline ---------- */
-- What: all incidents of one airline (id, date, severity, fatalities, registration, model).
-- Why:  a parameterised view; with CROSS APPLY it runs once per airline row in a report query. Archived incidents are
--       included (history), soft-deleted ones are not.
-- Who:  Member A
CREATE FUNCTION dbo.fn_IncidentsByAirline (@airline_id INT)
RETURNS TABLE
AS
RETURN
  SELECT i.incident_id, i.incident_date, i.severity, i.fatalities,
         a.registration_no AS registration, t.model
  FROM dbo.Incident i
  JOIN dbo.Aircraft a      ON a.aircraft_id = i.aircraft_id
  JOIN dbo.Aircraft_Type t ON t.type_id     = a.type_id
  WHERE a.airline_id = @airline_id AND i.is_deleted = 0;
GO

/* ---------- fn_SimilarIncidents ---------- */
-- What: the most similar other incidents to a given one, with a score and the reasons as text.
-- Why:  score = +3 same primary cause, +2 same aircraft type, +1 same phase of flight, +1 same airport (maximum 7).
--       Rows with score 0 are not returned; the incident itself and soft-deleted incidents are excluded.
--       Call it as: SELECT * FROM dbo.fn_SimilarIncidents(10, 5);   (a function cannot skip a default, so pass both values)
-- Who:  Member A
CREATE FUNCTION dbo.fn_SimilarIncidents (@incident_id INT, @top INT = 5)
RETURNS TABLE
AS
RETURN
  WITH base AS (
    SELECT i.incident_id, i.airport_id, i.phase_of_flight, a.type_id,
           (SELECT TOP 1 ic.cause_id FROM dbo.Incident_Cause ic
             WHERE ic.incident_id = i.incident_id AND ic.is_primary = 1) AS cause_id
    FROM dbo.Incident i
    JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
    WHERE i.incident_id = @incident_id
  ),
  cand AS (
    SELECT o.incident_id, o.incident_date, o.severity, al.name AS airline, a.registration_no AS registration,
           CASE WHEN pc.cause_id IS NOT NULL AND pc.cause_id = b.cause_id THEN 1 ELSE 0 END AS same_cause,
           CASE WHEN a.type_id = b.type_id THEN 1 ELSE 0 END                                AS same_type,
           CASE WHEN o.phase_of_flight = b.phase_of_flight THEN 1 ELSE 0 END                AS same_phase,
           CASE WHEN o.airport_id IS NOT NULL AND o.airport_id = b.airport_id THEN 1 ELSE 0 END AS same_airport
    FROM base b
    JOIN dbo.Incident o        ON o.incident_id <> b.incident_id AND o.is_deleted = 0
    JOIN dbo.Aircraft a        ON a.aircraft_id = o.aircraft_id
    JOIN dbo.Airline al        ON al.airline_id = a.airline_id
    LEFT JOIN dbo.Incident_Cause pc ON pc.incident_id = o.incident_id AND pc.is_primary = 1
  )
  SELECT TOP (@top)
         incident_id, incident_date, severity, airline, registration,
         same_cause * 3 + same_type * 2 + same_phase + same_airport AS score,
         CONCAT_WS(', ',
           CASE WHEN same_cause   = 1 THEN 'same cause'         END,
           CASE WHEN same_type    = 1 THEN 'same aircraft type' END,
           CASE WHEN same_phase   = 1 THEN 'same phase'         END,
           CASE WHEN same_airport = 1 THEN 'same airport'       END) AS reasons,
         same_cause, same_type, same_phase, same_airport
  FROM cand
  WHERE same_cause + same_type + same_phase + same_airport > 0
  ORDER BY same_cause * 3 + same_type * 2 + same_phase + same_airport DESC, incident_date DESC, incident_id DESC;
GO
/* ---------- v_aircraft_risk ---------- */
-- What: one row per aircraft with its risk breakdown, the uncapped total, the capped score (task book), a fleet percentile, a colour band and a rank.
-- Why:  FIX for the flat 100.0 problem. On the 10,000-incident demo data almost every aircraft has far more than 100 points, so the capped
--       score cannot tell aircraft apart. risk_percentile (0 = least risky, 100 = riskiest, compared with the whole fleet) always spreads out,
--       so the dashboard (A13) uses it for the colour band and raw_total for ordering and the bar chart. risk_score stays as the absolute,
--       capped score from the task book. Bands on the percentile: 0 to 30 green, 31 to 60 amber, above 60 red.
-- Who:  Member A
CREATE VIEW dbo.v_aircraft_risk AS
SELECT r.aircraft_id, r.registration_no, r.airline_id, r.airline,
       r.incident_points, r.fatality_points, r.age_points, r.overdue_points,
       r.raw_total,
       CAST(CASE WHEN r.raw_total > 100 THEN 100 ELSE r.raw_total END AS DECIMAL(5,1)) AS risk_score,
       r.risk_percentile,
       CASE WHEN r.risk_percentile <= 30 THEN 'green' WHEN r.risk_percentile <= 60 THEN 'amber' ELSE 'red' END AS risk_band,
       RANK() OVER (ORDER BY r.raw_total DESC) AS risk_rank
FROM (
  SELECT a.aircraft_id, a.registration_no, a.airline_id, al.name AS airline,
         b.incident_points, b.fatality_points, b.age_points, b.overdue_points, b.raw_total,
         CAST(100.0 * PERCENT_RANK() OVER (ORDER BY b.raw_total) AS DECIMAL(5,1)) AS risk_percentile
  FROM dbo.Aircraft a
  JOIN dbo.Airline al ON al.airline_id = a.airline_id
  CROSS APPLY dbo.fn_AircraftRiskBreakdown(a.aircraft_id) b
) r;
GO
PRINT 'A6 functions and v_aircraft_risk created.';
GO
