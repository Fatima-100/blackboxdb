# A10 notes: Incident report wizard (Member A)

## Files
- `wizard_routes.py`: all the wizard logic (routes, server checks, the call to `sp_AddIncident`)
- `templates/wizard.html`: one template for the 5 steps (progress bar, JavaScript checks, airport search, crew rows)
- `test_wizard.py`: the 5 scenarios from the task book, run against your real database

## Wiring (3 small edits)
1. `app.py`, just before `if __name__ == "__main__":`
   ```python
   import wizard_routes
   wizard_routes.register(app, PERMS)      # Admin and Investigator only, like the old form
   ```
2. `templates/base.html`: change the "Add incident" button link from `/incident/new` to `/incident/new/1?new=1`.
   Search for other links with `findstr /s /n "incident/new" templates\*.html`.
3. Optional: make the old form send people to the wizard. First line inside the old `incident_new()` in `app.py`:
   `return redirect(url_for("wizard_step", step=1, new=1))`

## How it works
- URLs: `/incident/new/1` to `/incident/new/5`. Answers are kept in `session['wizard']` as raw form values per step
  (`d1`..`d4`) plus a list `ok` of the steps that passed the server checks.
- Nothing is written to the database until Submit on step 5. Submit re-checks every step, then runs ONE batch:
  `DECLARE @c CauseList, @w CrewList; INSERT ...; EXEC sp_AddIncident ... @new_id = @id OUTPUT; SELECT @id;`
  All user values are `?` parameters, never joined into the SQL text.
- Step 1 loads the aircraft list for the chosen airline (`/incident/new/aircraft`) and shows a red note for Grounded or Retired aircraft.
- Step 2 checks: date valid, not in the future, not before `year_built`; location or airport required; fatalities and injuries 0 or more; only a Fatal incident can have fatalities; fatalities not more than passengers plus crew; the same aircraft + date + phase is shown with a link to the existing incident.
- Step 3: causes grouped by category, one radio for the primary cause; at least one cause and exactly one primary.
- Step 4: up to 6 crew rows (no duplicates), optional weather.
- Step 5: summary with an Edit link per step. Going back never loses answers; refresh keeps them too (they live in the session, not on the page).
- Database errors are mapped to a step and a friendly sentence (50101 crew/fatal check, 50110 no cause, 50111 not exactly one primary). `uq_incident_event` shows the "already recorded" sentence on step 2.
- Progress bar, Back on each step, JavaScript checks before Next, and a browser warning when leaving with unsaved changes.

## Viva prep
- **Why one transaction in the procedure:** the incident, its causes, weather and crew are one fact. Either all are saved or none, so a half-saved incident can never exist.
- **What if the 3rd insert fails:** `XACT_ABORT ON` + the CATCH block roll back the whole transaction, so the incident and the earlier inserts disappear and the error is re-thrown with THROW.
- **Why a wizard is safer than one long form:** every step is checked on its own, mistakes are shown next to the fields that caused them, answers are not lost, and the database is touched once, at the end, through one procedure.
- **Why the checks run twice (browser and server):** JavaScript is only a convenience; a user can bypass it, so the server checks are the real rule.

## Assumptions to check
- The lists of phases, weather types, crew roles and injury statuses are read from the existing data (DISTINCT values), so they always match the table rules. If a value has never been used it will not appear.
- The fatalities-versus-crew rule on step 2 uses passengers plus the maximum of 6 crew rows, because crew is chosen later on step 4.
- Error codes 50001 to 50007 and 50102 to 50105 are not mapped to special sentences yet, because their messages are in triggers I have not seen. They show the cleaned database message on the step the keywords point to (otherwise on step 5).
- Answers are kept in the Flask session cookie (about 4 KB limit). Description is limited to 1000 characters and location to 255 so it always fits.
