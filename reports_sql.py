REPORTS = [
 ("1. Most common primary cause per aircraft type", """
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
WHERE rn = 1 ORDER BY occurrences DESC"""),
 ("2. Airlines with the most unresolved recommendations", """
SELECT al.name AS airline, COUNT(*) AS unresolved
FROM Safety_Recommendation r JOIN Airline al ON al.airline_id = r.airline_id
WHERE r.status = 'Open'
GROUP BY al.airline_id, al.name HAVING COUNT(*) >= 1
ORDER BY unresolved DESC"""),
 ("3. Average investigation duration (days) by severity", """
SELECT i.severity,
       CAST(AVG(CAST(DATEDIFF(day, inv.start_date, inv.end_date) AS FLOAT)) AS DECIMAL(10,1)) AS avg_days,
       COUNT(*) AS investigations
FROM Investigation inv JOIN Incident i ON i.incident_id = inv.incident_id
WHERE inv.end_date IS NOT NULL
GROUP BY i.severity ORDER BY avg_days DESC"""),
 ("4. Fatalities by phase of flight", """
SELECT phase_of_flight, SUM(fatalities) AS fatalities, COUNT(*) AS incidents
FROM Incident GROUP BY phase_of_flight ORDER BY fatalities DESC"""),
 ("5. Airlines where the same cause appears in 2+ incidents", """
SELECT al.name AS airline, c.cause_name AS cause, COUNT(DISTINCT i.incident_id) AS incidents
FROM Incident i
JOIN Aircraft a ON a.aircraft_id = i.aircraft_id
JOIN Airline al ON al.airline_id = a.airline_id
JOIN Incident_Cause ic ON ic.incident_id = i.incident_id
JOIN Cause c ON c.cause_id = ic.cause_id
GROUP BY al.airline_id, al.name, c.cause_id, c.cause_name
HAVING COUNT(DISTINCT i.incident_id) >= 2
ORDER BY incidents DESC"""),
]
