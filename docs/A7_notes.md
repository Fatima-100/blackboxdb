# A7 notes - incident triggers (Member A)

Files: `objects_a_A7.sql` (5 triggers + drop of the old audit trigger), `objects_a_A7_view.sql` (trg_vfull_insert), `demo_a_A7.sql` (14 tests).
Run order: objects_a_A7.sql, then objects_a_A7_view.sql, then demo_a_A7.sql.

| Trigger | Table / event | What it does | Error |
|---|---|---|---|
| trg_incident_date (edited) | Incident, AFTER INSERT/UPDATE | future date, before aircraft built, after investigation start; soft-deleted rows ignored | 50001, 50006, 50007 |
| trg_incident_softdelete | Incident, INSTEAD OF DELETE | sets is_deleted = 1 and deleted_at; the row stays | - |
| trg_incident_audit_full | Incident, AFTER INSERT/UPDATE | INSERT: 1 log row. UPDATE: 1 row per changed column of the 7 audited ones. 0 -> 1 on is_deleted is action DELETE | - |
| trg_crew_fatal_check | Incident_Crew, AFTER INSERT/UPDATE | Fatal crew count may not exceed Incident.fatalities | 50101 |
| trg_aircraft_ground | Incident, AFTER INSERT | Major/Fatal incident sets an Active aircraft to Grounded | - |
| trg_vfull_insert | v_incident_full, INSTEAD OF INSERT | MERGE ... ON 1 = 0 + OUTPUT INTO maps new ids to source rows, then adds the primary cause | 50102 |

The old trg_incident_audit is dropped (the full audit replaces it).

## Things to know
- **Hard deletes in tests.** With the soft-delete trigger on, `DELETE FROM Incident` never removes anything. Every test script that cleans up
  Incident rows must wrap the cleanup like this (already done in demo_a_A7.sql):
  `DISABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;  <the DELETE statements>  ENABLE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident;`
  This still has to be added to demo_a.sql (A1), demo_a_A4.sql and demo_a_A6.sql.
- **Re-running the seed.** If seed.py runs AFTER these triggers exist, each of the 10,000 inserted incidents writes an INSERT audit row and every
  Major/Fatal incident grounds its aircraft (most of the 120 aircraft would end up Grounded). Run the seed before the triggers, or disable
  them around it. Decide this together with Member B for the final rebuild order.
- **Many rows.** All triggers use inserted/deleted as tables (set-based), so one statement that touches 1,000 rows works.
- **Nested triggers.** The soft-delete UPDATE fires the AFTER UPDATE triggers (date check and audit). That is wanted: the delete is audited.
  Recursive triggers are off by default, so a trigger does not re-fire itself.
- **How to switch one off:** `DISABLE TRIGGER dbo.trg_aircraft_ground ON dbo.Incident;` and `ENABLE TRIGGER ...`.
- **SET options.** Incident is used by an indexed view (A5), so statements that change it need QUOTED_IDENTIFIER, ANSI_NULLS and ARITHABORT ON.
  SSMS and pyodbc use these by default; the trigger files set them explicitly.

## Viva answers
- **inserted and deleted:** two virtual tables that exist inside a trigger. INSERT: only inserted. DELETE: only deleted. UPDATE: deleted holds the old
  rows, inserted the new rows. They hold ALL rows of the statement, so triggers must be written for many rows.
- **AFTER vs INSTEAD OF:** AFTER runs once the change is made and can undo it with ROLLBACK; INSTEAD OF replaces the statement, so nothing happens
  unless the trigger does it (soft delete, inserts into a join view).
- **IF UPDATE(col):** true when the column appears in the SET list (or INSERT list), even if the value did not change; so we also compare old and new.
- **Why not a CHECK constraint for the crew rule:** it compares two tables; CHECK sees only its own row.
- **Why MERGE ... ON 1 = 0:** the join never matches, so every row is inserted, and MERGE (unlike INSERT) can OUTPUT a column of the source row
  next to the new identity value, which pairs each new Incident with its cause.
