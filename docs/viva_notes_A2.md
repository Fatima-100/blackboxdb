# Viva notes - A2 (seed_a.py)  - append to docs/viva_notes.md

## Fixed demo set (incident_id 1 to 150 on a fresh database)
`random.seed(2026)` makes every run identical. The first 150 incidents are the demo set. IDs 1 to 6 are written by hand
in `FORCED` (seed_a.py) so the demo always has the same stories:

| ID | Date | Aircraft | Phase | Severity | Primary cause | Flight + airport |
|----|------|----------|-------|----------|---------------|------------------|
| 1 | 2016-03-14 | AP-100 (Skyline Air) | Takeoff | Fatal | Engine failure | yes (Cape Town) |
| 2 | 2025-09-02 | AP-100 | Approach | Serious | Engine failure | yes (Seattle), status Open |
| 3 | 2008-11-20 | AP-100 | Taxi | Minor | Engine failure | no |
| 4 | 2021-06-09 | AP-101 | Landing | Major | Pilot error | yes (Miami) |
| 5 | 2019-01-27 | AP-102 | Approach | Fatal | Windshear | yes (Shanghai) |
| 6 | 2024-05-18 | AP-103 | Climb | Minor | Bird strike | no |

Aircraft AP-100 has three Engine failure incidents (IDs 1 to 3): use it for "repeat cause" and aircraft risk demos.
(Check the table against your own run with `SELECT ... FROM Incident WHERE incident_id <= 6`.)

## Numbers after a run
62 airports, 12 airlines, 25 aircraft types, 16 causes, 200 crew, 120 aircraft, 534 maintenance rows, 5,989 flights,
10,000 incidents, 10,000 weather rows, 19,859 incident-cause rows, 29,823 incident-crew rows.
Severity about 45/30/15/10 %. Status: 30 Open, 364 Under Investigation, 9,606 Closed.
43 aircraft have their latest maintenance due date in the past (the overdue warning).

## Why a bigger data set (viva)
With 150 rows every query is instant, so an index makes no visible difference. With 10,000 incidents and 30,000 crew rows,
a query plan with and without `ix_...` shows a real change (scan vs seek, logical reads), and the reports and charts look real.

## Why triggers were disabled during the bulk load, and how consistency was kept (viva)
`trg_incident_date` and `trg_incident_audit` would run once per batch row set and write thousands of audit rows, which is slow
and wrong for seed data (nobody "changed" anything). So the script runs `ALTER TABLE ... DISABLE TRIGGER ALL` first and
`ENABLE TRIGGER ALL` in a `finally` block (they are always switched back on, even after an error). Consistency was kept in
three ways: (1) the generator only creates valid rows (incident date between 1995 and 2025, never before the aircraft's
`year_built`, never in the future); (2) `self_check()` re-tests every rule in Python before anything is inserted;
(3) after the load, SQL queries count violations (future dates, date before build year, not exactly one primary cause,
missing weather) and the script stops if any count is not 0. Statuses are set by the script from the incident date.

## Other design answers
- Why generate in memory first, then `executemany` with `fast_executemany`: one round trip per 1,000 rows instead of one per row, so 10,000 incidents load in seconds.
- Why the status uses a fixed date (2026-01-01), not today: so the data is the same on both laptops on any day. Only maintenance dates use today's date, so the overdue warning is always meaningful.
- Why exactly one primary cause: the filtered unique index `uq_one_primary_cause` allows only one row with `is_primary = 1` per incident.
- Real airports: 62 hard-coded rows in `data/airports.csv` (IATA, ICAO, name, city, country, latitude, longitude); coordinates are given to 4 decimals and stored as DECIMAL(9,6).
