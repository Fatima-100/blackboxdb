USE blackboxdb;
GO
/* DEMO / BACKUP SCRIPT - highlight ONE block at a time and press F5 */

-- TEST 1: future date is rejected by trigger (expect error 50001)
INSERT INTO Incident(aircraft_id,incident_date,location,phase_of_flight,severity)
VALUES (1, DATEADD(day,5,GETDATE()), 'Test', 'Cruise', 'Minor');

-- TEST 2: closing a recommendation with no response is rejected (expect error 50002)
UPDATE Safety_Recommendation SET status='Closed'
WHERE rec_id = (SELECT TOP 1 rec_id FROM Safety_Recommendation WHERE status='Open' ORDER BY rec_id);

-- TEST 3: ending an investigation auto-closes the incident
UPDATE Investigation SET end_date = CAST(GETDATE() AS DATE)
WHERE investigation_id = (SELECT TOP 1 investigation_id FROM Investigation WHERE end_date IS NULL ORDER BY investigation_id);

-- TEST 4: closing WITH a response works
UPDATE Safety_Recommendation SET status='Closed', response_text='Procedure updated'
WHERE rec_id = (SELECT TOP 1 rec_id FROM Safety_Recommendation WHERE status='Open' ORDER BY rec_id);

-- TEST 5: inserting a Closed recommendation with no response is rejected (error 50002)
INSERT INTO Safety_Recommendation(incident_id,airline_id,rec_text,issued_date,due_date,status)
VALUES (1, 1, 'Test', CAST(GETDATE() AS DATE), DATEADD(day,30,GETDATE()), 'Closed');

-- TEST 6: investigation starting in the future is rejected (error 50003)
INSERT INTO Investigation(incident_id,lead_investigator_id,start_date)
SELECT TOP 1 incident_id, 1, DATEADD(day,3,GETDATE()) FROM Incident
WHERE incident_id NOT IN (SELECT incident_id FROM Investigation);

-- TEST 7: incident dated before its aircraft was built is rejected (error 50006)
INSERT INTO Incident(aircraft_id,incident_date,location,phase_of_flight,severity)
SELECT TOP 1 aircraft_id, DATEFROMPARTS(year_built - 1, 1, 1), 'Test', 'Cruise', 'Minor'
FROM Aircraft ORDER BY year_built DESC;

-- TEST 8: a second primary cause for one incident is rejected (unique index error 2601)
UPDATE Incident_Cause SET is_primary = 1
WHERE incident_id = (SELECT TOP 1 incident_id FROM Incident_Cause GROUP BY incident_id HAVING COUNT(*) > 1 ORDER BY incident_id);

-- TEST 9: the same aircraft + date + phase twice is rejected (unique constraint error 2627)
INSERT INTO Incident(aircraft_id,incident_date,location,phase_of_flight,severity)
SELECT TOP 1 aircraft_id, incident_date, 'Duplicate test', phase_of_flight, 'Minor' FROM Incident ORDER BY incident_id;

-- Audit log and views
SELECT TOP 20 * FROM Audit_Log ORDER BY log_id DESC;
SELECT * FROM v_overdue_recommendations ORDER BY days_overdue DESC;
SELECT * FROM v_airline_safety_summary ORDER BY unresolved_recs DESC;
SELECT * FROM v_incidents_by_year ORDER BY yr, severity;

-- THE FIVE REPORT QUERIES
-- 1. Most common primary cause per aircraft type
SELECT model AS aircraft_type, cause, occurrences FROM (
  SELECT t.model, c.cause_name AS cause, COUNT(*) AS occurrences,
         RANK() OVER (PARTITION BY t.type_id ORDER BY COUNT(*) DESC) AS rn
  FROM Incident_Cause ic
  JOIN Incident i ON i.incident_id = ic.incident_id
  JOIN Aircraft a ON a.aircraft_id = i.aircraft_id
  JOIN Aircraft_Type t ON t.type_id = a.type_id
  JOIN Cause c ON c.cause_id = ic.cause_id
  WHERE ic.is_primary = 1
  GROUP BY t.type_id, t.model, c.cause_id, c.cause_name) x
WHERE rn = 1 ORDER BY occurrences DESC;

-- 2. Airlines with the most unresolved recommendations
SELECT al.name AS airline, COUNT(*) AS unresolved
FROM Safety_Recommendation r JOIN Airline al ON al.airline_id = r.airline_id
WHERE r.status = 'Open'
GROUP BY al.airline_id, al.name HAVING COUNT(*) >= 1
ORDER BY unresolved DESC;

-- 3. Average investigation duration (days) by severity
SELECT i.severity,
       CAST(AVG(CAST(DATEDIFF(day, inv.start_date, inv.end_date) AS FLOAT)) AS DECIMAL(10,1)) AS avg_days,
       COUNT(*) AS investigations
FROM Investigation inv JOIN Incident i ON i.incident_id = inv.incident_id
WHERE inv.end_date IS NOT NULL
GROUP BY i.severity ORDER BY avg_days DESC;

-- 4. Fatalities by phase of flight
SELECT phase_of_flight, SUM(fatalities) AS fatalities, COUNT(*) AS incidents
FROM Incident GROUP BY phase_of_flight ORDER BY fatalities DESC;

-- 5. Airlines where the same cause appears in 2+ incidents
SELECT al.name AS airline, c.cause_name AS cause, COUNT(DISTINCT i.incident_id) AS incidents
FROM Incident i
JOIN Aircraft a ON a.aircraft_id = i.aircraft_id
JOIN Airline al ON al.airline_id = a.airline_id
JOIN Incident_Cause ic ON ic.incident_id = i.incident_id
JOIN Cause c ON c.cause_id = ic.cause_id
GROUP BY al.airline_id, al.name, c.cause_id, c.cause_name
HAVING COUNT(DISTINCT i.incident_id) >= 2
ORDER BY incidents DESC;
