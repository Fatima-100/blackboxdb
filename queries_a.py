"""queries_a.py - A9: Query Library, group 1 (23 fixed, labelled queries).

Each item: id, clause (tag), question (business question), sql, why (why it is
useful for air safety) and if_removed (viva: what changes if the clause is
removed).  The list is FIXED: users pick an ID, they never type SQL, and no
user text is ever joined into a query (so there is no SQL injection here).
Every query ignores deleted incidents (is_deleted = 0).
"""

_LIVE = "i.is_deleted = 0"

QUERIES = [
 {"id": "Q1", "clause": "DISTINCT",
  "question": "Which years had at least one incident?",
  "sql": """SELECT DISTINCT YEAR(i.incident_date) AS incident_year
FROM dbo.Incident i
WHERE i.is_deleted = 0
ORDER BY incident_year""",
  "why": "Shows the years covered by the data and any gap years with no reports.",
  "if_removed": "The same year would be repeated once for every incident (10,000+ rows)."},

 {"id": "Q2", "clause": "TOP",
  "question": "The 10 incidents with the most fatalities.",
  "sql": """SELECT TOP 10 i.incident_id, i.incident_date, i.location, i.phase_of_flight, i.fatalities
FROM dbo.Incident i
WHERE i.is_deleted = 0
ORDER BY i.fatalities DESC, i.incident_id""",
  "why": "Investigators start with the deadliest events first.",
  "if_removed": "All incidents would be returned instead of only the worst 10."},

 {"id": "Q3", "clause": "TOP ... WITH TIES",
  "question": "Top 5 by fatalities, keeping ties.",
  "sql": """SELECT TOP (5) WITH TIES i.incident_id, i.incident_date, i.location, i.fatalities
FROM dbo.Incident i
WHERE i.is_deleted = 0
ORDER BY i.fatalities DESC""",
  "why": "Incidents with the same fatality count are equally serious, so none is cut off unfairly.",
  "if_removed": "Exactly 5 rows would be returned and tied incidents would be dropped at random."},

 {"id": "Q4", "clause": "ORDER BY (two columns)",
  "question": "Sort by severity (worst first), then newest date.",
  "sql": """SELECT TOP 100 i.incident_id, i.severity, i.incident_date, i.location
FROM dbo.Incident i
WHERE i.is_deleted = 0
ORDER BY CASE i.severity WHEN 'Fatal' THEN 4 WHEN 'Major' THEN 3 WHEN 'Serious' THEN 2 ELSE 1 END DESC,
         i.incident_date DESC""",
  "why": "A work list that shows the most severe and most recent cases at the top.",
  "if_removed": "Rows would come back in no guaranteed order; without the second column, same-severity rows are not sorted by date."},

 {"id": "Q5", "clause": "WHERE with AND, OR, NOT",
  "question": "Major or Fatal incidents in Takeoff or Landing that are not Closed.",
  "sql": """SELECT i.incident_id, i.incident_date, i.severity, i.phase_of_flight, i.status
FROM dbo.Incident i
WHERE i.is_deleted = 0
  AND (i.severity = 'Major' OR i.severity = 'Fatal')
  AND (i.phase_of_flight = 'Takeoff' OR i.phase_of_flight = 'Landing')
  AND NOT i.status = 'Closed'
ORDER BY i.incident_date DESC""",
  "why": "Finds the serious, still-open cases in the two riskiest phases of flight.",
  "if_removed": "Without NOT, closed cases would appear; without the brackets, OR would mix with AND and return the wrong rows."},

 {"id": "Q6", "clause": "IN and NOT IN",
  "question": "Incidents for chosen aircraft types, and for all other types (counts).",
  "sql": """SELECT 'IN (types 1,2,3)' AS filter, COUNT(*) AS incidents
FROM dbo.Incident i JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
WHERE i.is_deleted = 0 AND a.type_id IN (1, 2, 3)
UNION ALL
SELECT 'NOT IN (types 1,2,3)', COUNT(*)
FROM dbo.Incident i JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
WHERE i.is_deleted = 0 AND a.type_id NOT IN (1, 2, 3)""",
  "why": "Compares the safety record of a group of aircraft types with the rest of the fleet.",
  "if_removed": "You would need one OR condition per type; the two counts together must equal all incidents."},

 {"id": "Q7", "clause": "BETWEEN",
  "question": "Incidents from 2010 to 2015.",
  "sql": """SELECT TOP 100 i.incident_id, i.incident_date, i.severity, i.location
FROM dbo.Incident i
WHERE i.is_deleted = 0
  AND i.incident_date BETWEEN '2010-01-01' AND '2015-12-31'
ORDER BY i.incident_date""",
  "why": "Looks at a fixed period, for example before and after a new safety rule.",
  "if_removed": "Incidents from every year would be returned; BETWEEN includes both end dates."},

 {"id": "Q8", "clause": "LIKE",
  "question": "Locations that start with, end with, or contain a text.",
  "sql": """SELECT match_type, incident_id, location FROM (
  SELECT TOP 5 'starts with Sa' AS match_type, i.incident_id, i.location FROM dbo.Incident i
    WHERE i.is_deleted = 0 AND i.location LIKE 'Sa%'
  UNION ALL
  SELECT TOP 5 'ends with ia', i.incident_id, i.location FROM dbo.Incident i
    WHERE i.is_deleted = 0 AND i.location LIKE '%ia'
  UNION ALL
  SELECT TOP 5 'contains on', i.incident_id, i.location FROM dbo.Incident i
    WHERE i.is_deleted = 0 AND i.location LIKE '%on%'
) x ORDER BY match_type, incident_id""",
  "why": "Staff often remember only part of a place name when searching for a report.",
  "if_removed": "= would only find a location that matches the whole text exactly."},

 {"id": "Q9", "clause": "IS NULL, IS NOT NULL",
  "question": "Incidents with no flight link, and with one (counts).",
  "sql": """SELECT 'no flight (IS NULL)' AS link_state, COUNT(*) AS incidents
FROM dbo.Incident i WHERE i.is_deleted = 0 AND i.flight_id IS NULL
UNION ALL
SELECT 'has flight (IS NOT NULL)', COUNT(*)
FROM dbo.Incident i WHERE i.is_deleted = 0 AND i.flight_id IS NOT NULL""",
  "why": "Shows how much of the data is linked to a flight, a data-quality check.",
  "if_removed": "'= NULL' never matches in SQL, so it would return 0 rows; IS NULL is the only correct test."},

 {"id": "Q10", "clause": "ANY and ALL",
  "question": "Fatalities more than ALL Serious incidents, and more than ANY Minor one.",
  "sql": """SELECT 'more than ALL Serious' AS test, x.incident_id, x.fatalities FROM (
  SELECT TOP 10 i.incident_id, i.fatalities FROM dbo.Incident i
  WHERE i.is_deleted = 0
    AND i.fatalities > ALL (SELECT s.fatalities FROM dbo.Incident s WHERE s.severity = 'Serious' AND s.is_deleted = 0)
  ORDER BY i.fatalities DESC, i.incident_id) x
UNION ALL
SELECT 'more than ANY Minor', y.incident_id, y.fatalities FROM (
  SELECT TOP 10 i.incident_id, i.fatalities FROM dbo.Incident i
  WHERE i.is_deleted = 0
    AND i.fatalities > ANY (SELECT m.fatalities FROM dbo.Incident m WHERE m.severity = 'Minor' AND m.is_deleted = 0)
  ORDER BY i.fatalities DESC, i.incident_id) y""",
  "why": "Finds incidents that are worse than a whole group (ALL) or worse than at least one member (ANY).",
  "if_removed": "A plain '>' with a subquery that returns many rows causes an error; ALL means 'bigger than the maximum', ANY means 'bigger than the minimum'."},

 {"id": "Q11", "clause": "COUNT, SUM, AVG, MIN, MAX",
  "question": "Summary numbers for each severity.",
  "sql": """SELECT i.severity,
       COUNT(*)            AS incidents,
       SUM(i.fatalities)   AS total_fatalities,
       AVG(CAST(i.fatalities AS DECIMAL(10,2))) AS avg_fatalities,
       MIN(i.incident_date) AS first_incident,
       MAX(i.incident_date) AS last_incident
FROM dbo.Incident i
WHERE i.is_deleted = 0
GROUP BY i.severity""",
  "why": "One-line health check of the whole database for the dashboard.",
  "if_removed": "Without the aggregate functions you only see raw rows, not the totals; without CAST, AVG of whole numbers is rounded down."},

 {"id": "Q12", "clause": "COUNT(DISTINCT)",
  "question": "Number of different airlines with incidents each year.",
  "sql": """SELECT YEAR(i.incident_date) AS incident_year,
       COUNT(*) AS incidents,
       COUNT(DISTINCT a.airline_id) AS airlines_involved
FROM dbo.Incident i JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
WHERE i.is_deleted = 0
GROUP BY YEAR(i.incident_date)
ORDER BY incident_year""",
  "why": "Shows whether problems are spread over many airlines or concentrated in a few.",
  "if_removed": "COUNT(*) would count incidents, not airlines, so the same airline would be counted many times."},

 {"id": "Q13", "clause": "STRING_AGG",
  "question": "All causes of one incident (incident 1) in one line.",
  "sql": """SELECT i.incident_id,
       STRING_AGG(c.cause_name, ', ') WITHIN GROUP (ORDER BY ic.is_primary DESC, c.cause_name) AS causes
FROM dbo.Incident i
JOIN dbo.Incident_Cause ic ON ic.incident_id = i.incident_id
JOIN dbo.Cause c ON c.cause_id = ic.cause_id
WHERE i.incident_id = 1
GROUP BY i.incident_id""",
  "why": "A report line can list every cause (primary first) without repeating the incident.",
  "if_removed": "You would get one row per cause instead of one line per incident."},

 {"id": "Q14", "clause": "GROUP BY",
  "question": "Incidents per airline.",
  "sql": """SELECT al.name AS airline, COUNT(*) AS incidents, SUM(i.fatalities) AS fatalities
FROM dbo.Incident i
JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
JOIN dbo.Airline al ON al.airline_id = a.airline_id
WHERE i.is_deleted = 0
GROUP BY al.name
ORDER BY incidents DESC""",
  "why": "Ranks airlines by number of incidents for oversight visits.",
  "if_removed": "SQL would reject the query (airline name next to COUNT without GROUP BY), or give one grand total."},

 {"id": "Q15", "clause": "HAVING",
  "question": "Airlines with more than 20 incidents.",
  "sql": """SELECT al.name AS airline, COUNT(*) AS incidents
FROM dbo.Incident i
JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
JOIN dbo.Airline al ON al.airline_id = a.airline_id
WHERE i.is_deleted = 0
GROUP BY al.name
HAVING COUNT(*) > 20
ORDER BY incidents DESC""",
  "why": "Flags airlines above a review threshold.",
  "if_removed": "Every airline would be listed, even those with 1 incident. WHERE cannot do this, because it runs before the groups are counted."},

 {"id": "Q16", "clause": "GROUP BY ROLLUP",
  "question": "Year and severity totals with sub-totals and a grand total (2020 to 2025).",
  "sql": """SELECT YEAR(i.incident_date) AS incident_year, i.severity, COUNT(*) AS incidents,
       GROUPING(YEAR(i.incident_date)) AS year_is_subtotal, GROUPING(i.severity) AS severity_is_subtotal
FROM dbo.Incident i
WHERE i.is_deleted = 0 AND i.incident_date >= '2020-01-01'
GROUP BY ROLLUP (YEAR(i.incident_date), i.severity)
ORDER BY GROUPING(YEAR(i.incident_date)), incident_year, GROUPING(i.severity), i.severity""",
  "why": "Gives a yearly report with sub-totals and a grand total in one query.",
  "if_removed": "A plain GROUP BY returns only the detail rows; the sub-total and grand-total rows disappear."},

 {"id": "Q17", "clause": "GROUP BY CUBE",
  "question": "Every combination of severity and phase of flight.",
  "sql": """SELECT i.severity, i.phase_of_flight, COUNT(*) AS incidents,
       GROUPING(i.severity) AS severity_is_total, GROUPING(i.phase_of_flight) AS phase_is_total
FROM dbo.Incident i
WHERE i.is_deleted = 0
GROUP BY CUBE (i.severity, i.phase_of_flight)
ORDER BY GROUPING(i.severity), i.severity, GROUPING(i.phase_of_flight), i.phase_of_flight""",
  "why": "Shows which phase is most dangerous overall and for each severity.",
  "if_removed": "ROLLUP would give totals in one direction only; CUBE also totals per phase across all severities."},

 {"id": "Q18", "clause": "GROUPING SETS",
  "question": "Totals by year, by phase and overall in one query.",
  "sql": """SELECT YEAR(i.incident_date) AS incident_year, i.phase_of_flight, COUNT(*) AS incidents
FROM dbo.Incident i
WHERE i.is_deleted = 0
GROUP BY GROUPING SETS ((YEAR(i.incident_date)), (i.phase_of_flight), ())
ORDER BY GROUPING(YEAR(i.incident_date)), incident_year, i.phase_of_flight""",
  "why": "Three summary tables for a report from one pass over the data.",
  "if_removed": "You would need three separate queries joined with UNION ALL."},

 {"id": "Q19", "clause": "PIVOT",
  "question": "Severity as columns, one row per year.",
  "sql": """SELECT incident_year, ISNULL([Minor],0) AS Minor, ISNULL([Serious],0) AS Serious,
       ISNULL([Major],0) AS Major, ISNULL([Fatal],0) AS Fatal
FROM (SELECT YEAR(incident_date) AS incident_year, severity FROM dbo.Incident WHERE is_deleted = 0) s
PIVOT (COUNT(severity) FOR severity IN ([Minor],[Serious],[Major],[Fatal])) p
ORDER BY incident_year""",
  "why": "This is the shape a stacked chart needs: one row per year, one column per severity.",
  "if_removed": "The data would be one row per (year, severity) pair, harder to read and chart."},

 {"id": "Q20", "clause": "UNPIVOT",
  "question": "Turn the pivot back into rows (year, severity, count).",
  "sql": """SELECT incident_year, severity, incidents
FROM (SELECT incident_year, ISNULL([Minor],0) AS Minor, ISNULL([Serious],0) AS Serious,
             ISNULL([Major],0) AS Major, ISNULL([Fatal],0) AS Fatal
      FROM (SELECT YEAR(incident_date) AS incident_year, severity FROM dbo.Incident WHERE is_deleted = 0) s
      PIVOT (COUNT(severity) FOR severity IN ([Minor],[Serious],[Major],[Fatal])) p) w
UNPIVOT (incidents FOR severity IN (Minor, Serious, Major, Fatal)) u
ORDER BY incident_year, severity""",
  "why": "Converts a wide report table back to tidy rows that can be filtered or loaded elsewhere.",
  "if_removed": "The data stays wide (one column per severity)."},

 {"id": "Q21", "clause": "OFFSET ... FETCH NEXT",
  "question": "Page 3 of the incident list, 25 per page.",
  "sql": """SELECT i.incident_id, i.incident_date, i.severity, i.location
FROM dbo.Incident i
WHERE i.is_deleted = 0 AND i.is_archived = 0
ORDER BY i.incident_date DESC, i.incident_id DESC
OFFSET 50 ROWS FETCH NEXT 25 ROWS ONLY""",
  "why": "Lists with thousands of rows must be shown one page at a time to stay fast.",
  "if_removed": "All 10,000+ rows would be sent to the browser at once."},

 {"id": "Q22", "clause": "FOR JSON PATH",
  "question": "One incident (incident 1) with its causes as JSON.",
  "sql": """SELECT CAST((
  SELECT i.incident_id, i.incident_date, i.severity, i.location,
         (SELECT c.cause_name AS cause, ic.is_primary AS [primary]
            FROM dbo.Incident_Cause ic JOIN dbo.Cause c ON c.cause_id = ic.cause_id
           WHERE ic.incident_id = i.incident_id FOR JSON PATH) AS causes
  FROM dbo.Incident i WHERE i.incident_id = 1
  FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS NVARCHAR(MAX)) AS json_result""",
  "why": "APIs and the map or chart pages receive data as JSON, built directly in SQL.",
  "if_removed": "The result would be normal rows and the causes could not be nested inside the incident."},

 {"id": "Q23", "clause": "FOR XML PATH",
  "question": "The same data (incident 1 with causes) as XML.",
  "sql": """SELECT CAST((
  SELECT i.incident_id AS '@id', i.incident_date AS date, i.severity AS severity, i.location AS location,
         (SELECT c.cause_name AS '@name', ic.is_primary AS '@primary'
            FROM dbo.Incident_Cause ic JOIN dbo.Cause c ON c.cause_id = ic.cause_id
           WHERE ic.incident_id = i.incident_id FOR XML PATH('cause'), TYPE) AS causes
  FROM dbo.Incident i WHERE i.incident_id = 1
  FOR XML PATH('incident'), TYPE) AS NVARCHAR(MAX)) AS xml_result""",
  "why": "Some regulators and older systems exchange incident reports as XML.",
  "if_removed": "The result would be normal rows instead of an XML document."},
]

TAGS = [q["clause"] for q in QUERIES]
BY_ID = {q["id"]: q for q in QUERIES}
