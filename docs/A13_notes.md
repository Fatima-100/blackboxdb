# A13 notes: Similar incident finder, Search, Risk Score, Demo Mode (Member A)

## Files
- [`objects_a_A13.sql`](../objects_a_A13.sql) — updates `sp_SearchIncidents` (multi-severity `STRING_SPLIT` + `i.description` for highlighting)
- [`a13_routes.py`](../a13_routes.py) — `/search`, `/risk`, `/admin/demo`, `/admin/demo/status`, and the `highlight_terms` Jinja filter
- [`templates/incident_detail.html`](../templates/incident_detail.html) & `app.py` — **Similar past incidents** card (`fn_SimilarIncidents(?, 5)`)
- [`templates/search.html`](../templates/search.html) — Advanced search page
- [`templates/risk.html`](../templates/risk.html) — Risk score dashboard (Aircraft & Airlines tabs, top-10 chart, clickable breakdown)
- [`templates/demo_mode.html`](../templates/demo_mode.html) — Admin-only Reset demo database + Viva checklist
- [`test_a13.py`](../test_a13.py) — automated checks for all 4 features
- `templates/base.html` — sidebar links for Search, Risk Score, and Demo Mode

## Setup & Verify
1. Run [`objects_a_A13.sql`](../objects_a_A13.sql) in SSMS (`F5`).
2. Run `python test_a13.py` in PowerShell → expect `9 of 9 checks passed -> ALL PASS`.

## Features & Viva Notes
- **Similar incident finder**: calls `dbo.fn_SimilarIncidents(?, 5)` (+3 same primary cause, +2 same aircraft type, +1 same phase, +1 same airport; max 7) and displays reason chips.
- **Advanced search (`/search`)**: all filters live in GET query parameters (shareable URLs), calls `dbo.sp_SearchIncidents` (parameterized `sp_executesql` + sort whitelist), supports multi-severity checkboxes via `STRING_SPLIT`, and highlights search words with `<mark>` after HTML-escaping.
- **Risk score (`/risk`)**: reads `dbo.v_aircraft_risk` (backed by `fn_AircraftRiskBreakdown` and `fn_AircraftRiskScore`). Shows capped 0–100 score, uncapped `raw_total`, fleet percentile band (0–30 green, 31–60 amber, >60 red), top-10 bar chart, clickable 4-part breakdown, and Airline averages.
- **Demo mode (`/admin/demo`)**: Admin-only. Requires typing `RESET`, executes the SQL scripts split on `GO` with `autocommit=True`, runs the seed script in a background thread, polls `/admin/demo/status`, and logs the reset in `Audit_Log`.
