# A4 and A5 notes (Member A)

## Files
- `objects_a_A4.sql`: table types CauseList and CrewList, then the 5 procedures
- `demo_a_A4.sql`: 10 tests in a PASS/FAIL grid + archive test (rolled back)
- `views_a_A5.sql`: the 5 views
- `demo_a_A5.sql`: TOP 5 of each view, check-option tests, indexed view proof

Error codes (A range 50100-50199): 50110 no cause, 50111 not exactly one primary, 50112 bad sort, 50113 bad page, 50114 bad year range, 50115 bad archive age. 50101-50105 stay free for the A7 triggers.

## Views: base tables, updatable?, why
| View | Base tables | Can it be updated? | Why |
|---|---|---|---|
| v_incident_full | Incident, Aircraft, Airline, Aircraft_Type, Aircraft_Category, Airport, Flight, Incident_Cause, Cause | No (not directly) | Joins many tables; an INSTEAD OF trigger in A7 will handle writes |
| v_fatal_incidents | Incident | Yes | One table, no aggregates. WITH CHECK OPTION rejects a change that makes the row non-fatal (error 550) |
| v_cause_trend | Incident, Incident_Cause, Cause | No | GROUP BY and window functions: rows are computed, not stored |
| v_incident_phase_stats | Incident | No | GROUP BY. It is an indexed view, so the result is stored, but you still write to Incident |
| v_incident_map | Incident, Airport, Aircraft, Airline | No | Join view; read-only data source for the map |

## Viva prep (short answers)
- **Procedure vs function:** a procedure can change data, return several result sets and OUTPUT values, and is called with EXEC. A function must return a value or table, cannot change data, and can be used inside a SELECT.
- **XACT_ABORT ON:** any run-time error rolls back the whole transaction automatically, so nothing is left half-saved.
- **THROW vs RAISERROR:** THROW re-raises the original error number and message (and is the modern way); RAISERROR needs a format string and changes the error.
- **Table-valued parameters:** pass a list of causes and crew in one call, so the whole incident is saved in one transaction with no string splitting.
- **SQL injection and the whitelist:** injection is user text becoming part of the SQL command. Filter values go in as parameters, and the sort is looked up in a fixed list, so no user text reaches the string.
- **ROWVERSION:** an 8-byte number that changes on every update. Update only if it still matches what the user loaded, otherwise return -1 (someone else changed it).
- **SAVE TRAN in the archive loop:** a failed batch is undone to its savepoint while earlier batches are kept. XACT_ABORT is off there on purpose.
- **View is not storage:** a normal view is a saved SELECT. An indexed view (SCHEMABINDING + unique clustered index) stores its result, so reads are fast but every write to Incident must also update it.
- **Indexed view rules:** two-part names, COUNT_BIG(*), no nullable expression in SUM.
- **Insert through a join view:** only if the insert touches one base table; with several tables use an INSTEAD OF trigger.

## Assumptions to check
- Column names: Incident.status, Aircraft.registration_no, Aircraft.type_id, Aircraft_Type.model, Aircraft_Type.category_id, Cause.cause_name (taken from app.py and the task book).
- VARCHAR sizes in the procedure parameters (location 255, description 1000): if your table columns are shorter, saving a very long value fails with a truncation error.
- SQL Server Express/Standard does not pick an indexed view automatically. Query it with `WITH (NOEXPAND)` (the demo does).
- SCHEMABINDING on Incident means you cannot ALTER the columns the view uses or DROP the table without dropping the view first. The rebuild script drops the whole database, so this is fine.
