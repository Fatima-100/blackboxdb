# A3 notes - real data import

## Data source and licence line (copy into README.md, section "Data sources and licences")
> Real accident records: NTSB Aviation Accident Database (https://data.ntsb.gov/avdata/), published by the US National
> Transportation Safety Board, a US federal government agency. The data.gov catalogue entry for the NTSB aviation
> data lists its use restriction as "Unrestricted". `data/real_sample.csv` is a random sample of 2,000 rows
> (fixed seed) converted to our import format with `tools/ntsb_to_import_csv.py`. Downloaded on <DATE>.
> `data/sample_import.csv` is simulated demo data (registrations IMP-101 to IMP-127), not real records.

Check before you cite it: the NTSB download page itself shows no licence text, and the data.gov record says
"Unrestricted" (use) but "Restricted - Partly" (access, unexplained). Open https://data.ntsb.gov/avdata/ and the NTSB
Aviation Accident Database page once yourself and keep the exact wording you saw in the README.

## How to make data/real_sample.csv
1. Download an NTSB aviation accident CSV (for example an export of the Aviation Accident Database with the
   columns Event.Date, Location, Registration.Number, Air.carrier, Make, Model, Broad.phase.of.flight,
   Total.Fatal.Injuries, Total.Serious.Injuries, Total.Minor.Injuries, Weather.Condition). The official bulk
   files at data.ntsb.gov/avdata are Access (.mdb) files: export the `events` and `aircraft` tables to one CSV first.
2. `python tools/ntsb_to_import_csv.py AviationData.csv data/real_sample.csv --rows 2000`
   If a column is not found, the script prints the columns of your file and what it could not match.

## Column mapping: source column -> import file column -> Import_Staging column
| NTSB column | Import file column | Import_Staging column | Rule |
|---|---|---|---|
| Event.Date | date | raw_date | must be YYYY-MM-DD, a real date, not in the future, not before the aircraft was built |
| Location | location | raw_location | required |
| Registration.Number | registration | raw_registration | required, at most 12 characters; identifies the aircraft |
| Air.carrier | operator | raw_airline | blank becomes the airline "Unknown operator" |
| Make + Model | model | raw_model | first word = manufacturer, rest = model (a few two-word makers such as De Havilland are recognised) |
| Broad.phase.of.flight | phase | raw_phase | mapped to the 7 phases; unknown or blank becomes Cruise with a Warning |
| Total.Fatal.Injuries | fatalities | raw_fatalities | whole number, not negative, blank = 0 |
| Total.Serious + Total.Minor Injuries | injuries | raw_injuries | whole number, not negative, blank = 0 |
| Weather.Condition | weather | raw_weather | saved as the weather condition text |

Derived in SQL: severity = Fatal if fatalities > 0, Major if injuries >= 5, Serious if injuries >= 1, else Minor.
New airlines get country "Unknown"; new aircraft types get the category "Light"; imported incidents get status "Closed".
Phase mapping: STANDING->Taxi, TAKEOFF->Takeoff, MANEUVERING->Cruise, GO-AROUND->Approach, others as named.

## Objects (objects_a.sql, section A3)
- `fn_ImportParsed(@batch_id)`: inline table-valued function, one place for all parsing rules.
- `sp_ValidateImport(@batch_id)`: sets row_status and error_message; the /import preview uses it.
- `sp_ImportIncidents(@batch_id, @imported OUT, @skipped OUT, @errors OUT)`: imports in one transaction, writes the audit log.
- Error number 50101: import batch not found.
- Tests: `demo_a_A3.sql` (8 tests, all must be PASS).

## Demo check
Upload `data/sample_import.csv`: 30 rows, 27 imported (one with a phase warning), 3 errors:
row 8 impossible date, row 17 negative fatalities, row 24 missing registration.
Upload it again: 0 imported, 27 duplicates, the same 3 errors.

## Viva answers
- **Why a staging table?** Real files are dirty. Raw VARCHAR columns accept every row, so nothing is lost; the data is checked in SQL
  and only good rows reach the real tables. The admin sees all errors (with row numbers) before importing.
- **Why TRY_CONVERT instead of CONVERT?** CONVERT raises an error on the first bad value and stops the whole statement;
  TRY_CONVERT returns NULL, so we can mark just that row as Error and carry on.
- **What does MERGE do?** One statement that compares a source with a target and, per row, inserts, updates or deletes.
  Here it inserts only airlines, aircraft types and aircraft that are not there yet ("find or create").
- **What does OUTPUT return?** The rows a statement changed (for example `inserted.incident_id`). With MERGE ... ON 1 = 0 it can also return
  a column of the source (the staging row id) next to the new id; that is how each weather row finds its incident.
- **How are duplicates found?** An incident is "the same event" when aircraft + date + phase match (the UNIQUE rule on Incident).
  Checked against the Incident table, and with ROW_NUMBER() inside the file (first row stays, later copies are Duplicate).
- **Why one transaction?** If anything fails halfway, ROLLBACK leaves the real tables as they were; the batch is marked Failed.
- **Why does validation also check the aircraft's year_built?** The trigger trg_incident_date would reject that row and roll back the whole batch; checking first turns it into one clear error row.

## Flask page (import_routes.py + templates/import*.html)
Wiring (3 small edits):
1. `app.py`, before `if __name__ == "__main__":` add
   ```python
   import import_routes
   import_routes.register(app, PERMS)
   ```
   (`register` adds the 5 routes and puts them in PERMS for Admin and Officer only, so the existing `guard()` protects them.)
2. `templates/base.html`, in the `<nav>` after the Reports link add
   ```html
   {% if role in ('Admin', 'Officer') %}<a class="nav-item {{ 'active' if request.endpoint in ('import_page','import_preview','import_result') }}" href="/import">Import data</a>{% endif %}
   ```
3. Copy `import_routes.py` to the project root and `templates/import.html`, `import_preview.html`, `import_result.html` into `templates/`.

Pages: `/import` (upload + history), `/import/<id>` (preview, error list, "Import valid rows"), `/import/<id>/result`,
`/import/<id>/errors.csv` (download error rows; same columns as the upload plus `row` and `error`, so it can be fixed and uploaded again).
Limits: .csv only, UTF-8 (a UTF-8 BOM is accepted), 5 MB, 20,000 rows, `;` or `,` separated. Every bad file gives a red message, never a crash.
The audit-log entry (who imported which file) is written by sp_ImportIncidents using the logged-in user name.
