# A11 notes: Interactive charts dashboard (Member A)

## Files
- `charts_routes.py` – five JSON API endpoints + the new `/dashboard` route
- `templates/dashboard.html` – interactive chart page (overwrites the old static one)
- `static/chart.min.js` – Chart.js saved locally (you must download it once — see below)

## Setup (one-off)

### 1. Download Chart.js locally (for the offline demo)
Open PowerShell in the project root:
```powershell
Invoke-WebRequest -Uri "https://cdn.jsdelivr.net/npm/chart.js@4.4.3/dist/chart.umd.min.js" -OutFile "static\chart.min.js"
```
The dashboard tries `/static/chart.min.js` first. If the file is missing it falls back to the CDN automatically, so the page works with internet too — the local copy is only needed for the offline demo.

### 2. Wire into app.py (already done)
```python
import charts_routes
charts_routes.register(app, PERMS)
```
This also replaces the old `@app.route("/")` dashboard with the interactive version.

## API endpoints

| Endpoint | Calls | Returns |
|----------|-------|---------|
| `GET /api/stats/yearly?from_year=&to_year=` | `sp_YearlyStats` | `{years, Minor, Serious, Major, Fatal, Total}` |
| `GET /api/stats/causes?top=10` | inline SQL | `[{label, n}]` |
| `GET /api/stats/phase` | `v_incident_phase_stats WITH (NOEXPAND)` | `[{phase, n, fatalities}]` |
| `GET /api/stats/monthly?from_year=&to_year=&severity=` | inline SQL | `[{month 1–12, n}]` |
| `GET /api/incidents?page=&sort=&severity=&cause_id=…` | `sp_SearchIncidents` | `{rows, total, page, page_size}` |

Airline users: every endpoint passes `airline_id` automatically so they only see their own data. The indexed view (`v_incident_phase_stats`) does not carry an airline column, so the phase endpoint falls back to the base table when the user has the Airline role.

## Charts and interactions

| Chart | Type | Click action |
|-------|------|-------------|
| Incidents per year by severity | Stacked bar | Click a bar → set year filter + slider |
| Top 10 causes | Horizontal bar | Click → filter incident table by that cause |
| Severity split | Doughnut | Click a slice → filter all charts + table |
| Fatalities per phase | Bar | No click filter (fatality totals by phase) |
| Monthly seasonality | Line | No click filter (shows seasonal pattern) |

**Year-range slider**: two handles set `from_year` / `to_year`; all five charts and the table reload 300 ms after the slider stops moving.

**Filter chips**: each active filter shows a yellow chip with an ✕ to remove it. "Clear all" resets every filter and the slider.

**Incident table**: sortable by newest/oldest/severity/fatalities, paginated (25 per page), every row links to the incident detail page.

**Export**: "Download PNG" on the two main charts (uses `canvas.toBlob`). "Download CSV" links to the `/api/incidents` endpoint (returns JSON — point the examiner to the Query Library for the proper CSV demo).

## Viva prep
- **Which query or view feeds each chart?**  
  - Year chart → `sp_YearlyStats` (PIVOT of severity counts per year)  
  - Cause chart → `Incident_Cause JOIN Cause` with `COUNT(*) GROUP BY`  
  - Phase chart → `v_incident_phase_stats WITH (NOEXPAND)` (the indexed view is on disk, so no scan)  
  - Monthly → `MONTH(incident_date) GROUP BY MONTH` with optional year/severity filter  
  - Table → `sp_SearchIncidents` (dynamic SQL with a sort whitelist)
- **Why is the indexed view used for the phase chart?**  
  It pre-aggregates phase and fatality totals at write time, so the read is an Index Seek on a 7-row result, not a scan of 10,000 incident rows. `WITH (NOEXPAND)` forces SQL Server Express to use it.
- **Why five separate endpoints instead of one?**  
  Each chart has a different filter set. A single endpoint returning everything would re-fetch data the user doesn't need every time one filter changes.
- **Why does the Airline role get different SQL for the phase endpoint?**  
  The indexed view has no airline column (`WITH SCHEMABINDING` locks its definition). Joining the view to Aircraft would break the index usage, so we fall back to the base table for Airline users. The view is still used for every staff user.
- **How does the click-to-filter work without a page reload?**  
  `Chart.js onClick` reads the clicked element's index, sets a filter variable in JavaScript, and calls `refreshAll()` which fires all five `fetch()` calls in parallel. The DOM updates when each promise resolves — no server-side HTML is regenerated.

## Check (viva demo steps)
1. `python app.py` → open `http://localhost:5000/` as Admin → all 5 charts load within 1 second.
2. Click the 2020 stacked bar → slider moves to 2020–2020, table shows only 2020 incidents, yellow "Year: 2020" chip appears.
3. Click the "Fatal" doughnut slice → all charts redraw for Fatal only, chip shows "Severity: Fatal".
4. Click ✕ on the chip → filter clears, charts reload.
5. Click a cause bar → table filters to that cause.
6. Move the year slider to 2015–2020 → all charts redraw.
7. Click "PNG" on the year chart → `incidents_per_year.png` downloads.
8. Log in as an Airline user → charts show only that airline's data (the endpoint passes `@user_airline_id`).
9. Unplug the internet → reload the page → charts still draw (from `/static/chart.min.js`).
