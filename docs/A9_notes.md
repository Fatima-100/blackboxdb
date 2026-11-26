# A9 notes: Query Library group 1 and SQL Lab (Member A)

## Files
- `queries_a.py`: the 23 fixed queries (ID, clause, business question, SQL, why it is useful, what changes if the clause is removed)
- `queries_routes.py` + `templates/queries.html`: the `/queries` page (tag filter, SQL, result table, run time)
- `test_queries_a.py`: runs all 23 and prints PASS/FAIL with run time (limit 2000 ms)
- `sql_lab.sql`: DML, DDL, transactions and functions on test copies only

## Wiring `/queries` into app.py (2 lines, same pattern as /import)
```python
import queries_routes
queries_routes.register(app, PERMS)   # staff roles only: Admin, Investigator, Officer
```
Then add one link in `templates/base.html`: `<a class="nav-item {{ 'active' if request.endpoint=='queries' }}" href="/queries">Query Library</a>` (inside the `role != 'Airline'` block).

## Why the list is fixed
Users choose an ID; the SQL comes only from `queries_a.py`. No user text is ever put into a query, so there is no SQL injection. An unknown ID runs nothing.

## Viva prep: business question and what changes if the clause is removed
| ID | Clause | Business question | If the clause is removed |
|---|---|---|---|
| Q1 | DISTINCT | Which years had at least one incident? | The same year would be repeated once for every incident (10,000+ rows). |
| Q2 | TOP | The 10 incidents with the most fatalities. | All incidents would be returned instead of only the worst 10. |
| Q3 | TOP ... WITH TIES | Top 5 by fatalities, keeping ties. | Exactly 5 rows would be returned and tied incidents would be dropped at random. |
| Q4 | ORDER BY (two columns) | Sort by severity (worst first), then newest date. | Rows would come back in no guaranteed order; without the second column, same-severity rows are not sorted by date. |
| Q5 | WHERE with AND, OR, NOT | Major or Fatal incidents in Takeoff or Landing that are not Closed. | Without NOT, closed cases would appear; without the brackets, OR would mix with AND and return the wrong rows. |
| Q6 | IN and NOT IN | Incidents for chosen aircraft types, and for all other types (counts). | You would need one OR condition per type; the two counts together must equal all incidents. |
| Q7 | BETWEEN | Incidents from 2010 to 2015. | Incidents from every year would be returned; BETWEEN includes both end dates. |
| Q8 | LIKE | Locations that start with, end with, or contain a text. | = would only find a location that matches the whole text exactly. |
| Q9 | IS NULL, IS NOT NULL | Incidents with no flight link, and with one (counts). | '= NULL' never matches in SQL, so it would return 0 rows; IS NULL is the only correct test. |
| Q10 | ANY and ALL | Fatalities more than ALL Serious incidents, and more than ANY Minor one. | A plain '>' with a subquery that returns many rows causes an error; ALL means 'bigger than the maximum', ANY means 'bigger than the minimum'. |
| Q11 | COUNT, SUM, AVG, MIN, MAX | Summary numbers for each severity. | Without the aggregate functions you only see raw rows, not the totals; without CAST, AVG of whole numbers is rounded down. |
| Q12 | COUNT(DISTINCT) | Number of different airlines with incidents each year. | COUNT(*) would count incidents, not airlines, so the same airline would be counted many times. |
| Q13 | STRING_AGG | All causes of one incident (incident 1) in one line. | You would get one row per cause instead of one line per incident. |
| Q14 | GROUP BY | Incidents per airline. | SQL would reject the query (airline name next to COUNT without GROUP BY), or give one grand total. |
| Q15 | HAVING | Airlines with more than 20 incidents. | Every airline would be listed, even those with 1 incident. WHERE cannot do this, because it runs before the groups are counted. |
| Q16 | GROUP BY ROLLUP | Year and severity totals with sub-totals and a grand total (2020 to 2025). | A plain GROUP BY returns only the detail rows; the sub-total and grand-total rows disappear. |
| Q17 | GROUP BY CUBE | Every combination of severity and phase of flight. | ROLLUP would give totals in one direction only; CUBE also totals per phase across all severities. |
| Q18 | GROUPING SETS | Totals by year, by phase and overall in one query. | You would need three separate queries joined with UNION ALL. |
| Q19 | PIVOT | Severity as columns, one row per year. | The data would be one row per (year, severity) pair, harder to read and chart. |
| Q20 | UNPIVOT | Turn the pivot back into rows (year, severity, count). | The data stays wide (one column per severity). |
| Q21 | OFFSET ... FETCH NEXT | Page 3 of the incident list, 25 per page. | All 10,000+ rows would be sent to the browser at once. |
| Q22 | FOR JSON PATH | One incident (incident 1) with its causes as JSON. | The result would be normal rows and the causes could not be nested inside the incident. |
| Q23 | FOR XML PATH | The same data (incident 1 with causes) as XML. | The result would be normal rows instead of an XML document. |

## SQL Lab: what each part shows
- **Setup:** `SELECT ... INTO Incident_Test ... WHERE 1 = 0` copies only the structure (no identity, triggers or constraints), then 500 rows are copied in. `row_ver` is left out because a ROWVERSION column cannot be inserted into.
- **DML:** INSERT, INSERT...SELECT, UPDATE with JOIN, DELETE, MERGE (update, insert and delete branches, with OUTPUT), SELECT INTO, TRUNCATE.
- **DDL:** CREATE TABLE, ALTER ADD COLUMN, ALTER COLUMN, ADD and DROP CONSTRAINT (with a failing insert shown), CREATE SEQUENCE with NEXT VALUE FOR, DROP TABLE.
- **Transactions:** ROLLBACK, COMMIT, and SAVE TRAN with a partial rollback; a SELECT after each step.
- **Functions:** CASE, IIF, COALESCE, ISNULL, NULLIF, UPPER, SUBSTRING, CONCAT, LEN, DATEDIFF, DATEADD, EOMONTH, FORMAT, ROUND, CAST, CONVERT.
- **Safety:** only `Incident_Test` and `lab_*` tables are changed; the real tables are only read. The script drops its own test tables at the end and prints the real Incident row count.

## Assumptions to check
- Q6 uses aircraft type ids 1, 2, 3 (the seed makes 25 types with ids 1 to 25).
- Q8 uses the text 'Sa', 'ia' and 'on'; if your locations look different the three groups may return fewer rows. Change the text, not the clause.
- Q13, Q22 and Q23 use incident 1 (a fixed demo incident).
- STRING_AGG needs SQL Server 2017 or newer.
- Q10: Minor and Serious incidents usually have 0 fatalities, so 'more than ALL Serious' returns the worst incidents and 'more than ANY Minor' returns almost every fatal one.
