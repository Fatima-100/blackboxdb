# A12 notes: Map view (Member A)

## Files
- [`objects_a_A12.sql`](../objects_a_A12.sql) — updates `v_incident_map` (adds `airline_id`, `registration`) and creates `sp_GetMapPoints`
- [`demo_a_A12.sql`](../demo_a_A12.sql) — 5 tests for `sp_GetMapPoints`
- [`map_routes.py`](../map_routes.py) — `/map` page and `/api/map` JSON endpoint
- [`templates/map.html`](../templates/map.html) — Leaflet map with marker clustering, heat-map toggle, filters, Fit-to-results, and offline GeoJSON fallback
- [`static/world_outline.geojson`](../static/world_outline.geojson) — local simplified world continent outlines for offline mode
- [`views_a_A5.sql`](../views_a_A5.sql) — updated `v_incident_map` definition
- `app.py`, `templates/base.html` — wired `map_routes` and added the `Map` sidebar link

## Setup

### 1. Run the SQL in SSMS (with `blackboxdb` selected)
1. Open `objects_a_A12.sql` and press `F5`.
2. Open `demo_a_A12.sql` and press `F5` — you should see 5 `PASS` rows.

### 2. Download Leaflet assets locally (for offline demo)
Run these commands in PowerShell from the project root (`blackboxdb/`):
```powershell
New-Item -ItemType Directory -Force static\leaflet | Out-Null
Invoke-WebRequest "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" -OutFile "static\leaflet\leaflet.css"
Invoke-WebRequest "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" -OutFile "static\leaflet\leaflet.js"
Invoke-WebRequest "https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.css" -OutFile "static\leaflet\MarkerCluster.css"
Invoke-WebRequest "https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.Default.css" -OutFile "static\leaflet\MarkerCluster.Default.css"
Invoke-WebRequest "https://unpkg.com/leaflet.markercluster@1.5.3/dist/leaflet.markercluster.js" -OutFile "static\leaflet\leaflet.markercluster.js"
Invoke-WebRequest "https://unpkg.com/leaflet.heat@0.2.0/dist/leaflet-heat.js" -OutFile "static\leaflet\leaflet-heat.js"
```
`map.html` tries `/static/leaflet/...` first and falls back to the CDN if missing, so it works online even before running the download.

## How it works
- `sp_GetMapPoints(@from_year, @to_year, @severity_list, @airline_id)` reads `v_incident_map` (only airport-linked, non-deleted incidents), filters severities with `STRING_SPLIT(@severity_list, ',')`, and returns `TOP (10000)` rows.
- Pin colours: Minor = green, Serious = yellow, Major = orange, Fatal = red.
- **Marker clustering** (`L.markerClusterGroup`) groups nearby pins so 6,000+ points render smoothly in under 3 seconds.
- **Heat map toggle** switches on `L.heatLayer` weighted by severity.
- **Offline fallback**: if OpenStreetMap tiles fail to load (3+ tile errors or `navigator.onLine === false`), the page automatically loads `static/world_outline.geojson` as a vector layer behind the pins and shows the "Offline mode" badge.
- **Airline role**: `/map` locks the airline dropdown and `/api/map` enforces `session["airline_id"]`.

## Viva prep
- **Why are `latitude` and `longitude` `DECIMAL(9,6)`?**  
  Latitude ranges from -90 to +90 (2 digits before decimal) and longitude from -180 to +180 (3 digits before decimal), plus 6 decimal places (~0.11 m precision) = 9 total digits, 6 after the decimal point. `DECIMAL` is exact (no floating-point rounding drift like `FLOAT`).
- **What does `STRING_SPLIT` do?**  
  It is a built-in table-valued function (SQL Server 2016+) that splits a delimited string like `'Minor,Fatal'` into a table of rows (`value`), letting us pass a comma-separated filter as one `@severity_list` parameter instead of building dynamic SQL.
- **Why `TOP (10000)`?**  
  Protects browser memory and keeps `/api/map` fast if the database grows to hundreds of thousands of rows.
