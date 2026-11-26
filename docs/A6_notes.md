# A6 notes - functions (Member A)

Files: `objects_a_A6.sql` (4 functions), `demo_a_A6.sql` (13 tests).

## Risk score formula (also in the header comment of fn_AircraftRiskScore)
score = incident points + fatality points + age points + overdue points, capped at 100

| Part | Rule |
|---|---|
| incident points | (Minor 1, Serious 3, Major 6, Fatal 10, added up for incidents in the last 10 years) x 4 |
| fatality points | 0.5 per fatality in the same 10 years |
| age points | (this year - year_built) / 3 |
| overdue points | 10 if the next_due_date of the LATEST maintenance record is in the past |

Dashboard colours: 0 to 30 green, 31 to 60 amber, above 60 red. Soft-deleted incidents are ignored.
Worked example (test aircraft): (10 + 1) x 4 = 44, + 2 x 0.5 = 1, + 30 / 3 = 10, + 10 = **65.0** (red band, because it is above 60).

## One deliberate difference from the task book
The task book says "10 if ANY maintenance next_due_date is in the past". With about 4 records per aircraft in the seed, almost every
aircraft has an old record whose due date has passed (it was done again later), so nearly all aircraft would get +10 and the
points would say nothing. The function uses the LATEST maintenance record, which is also the rule the seed and the "overdue"
warning use. Test 5 proves it. Tell the examiner / Member B if they expect "any".

## The four functions
| Function | Type | Used for |
|---|---|---|
| fn_AircraftRiskBreakdown(@aircraft_id) | inline table-valued | the four parts of the score (dashboard breakdown, A13) |
| fn_AircraftRiskScore(@aircraft_id) | scalar | the score itself (SELECT, WHERE, ORDER BY) |
| fn_IncidentsByAirline(@airline_id) | inline table-valued | airline reports with CROSS APPLY |
| fn_SimilarIncidents(@incident_id, @top) | inline table-valued | "Similar past incidents" card (A13) |

fn_SimilarIncidents: +3 same primary cause, +2 same aircraft type, +1 same phase, +1 same airport (maximum 7). Rows with score 0 are
not returned. Call it with both values: `SELECT * FROM dbo.fn_SimilarIncidents(10, 5);`

## Viva answers
- **Scalar vs table-valued:** scalar returns one value and can sit in SELECT/WHERE; table-valued returns rows and is used in FROM.
- **Why inline is faster than multi-statement:** the optimizer expands an inline function into the calling query (like a view) and
  uses real statistics; a multi-statement function fills a table variable first and the optimizer guesses its size.
- **Why a function cannot change data:** functions must be side-effect free so they can be used inside queries, in any order, any number of times.
- **Where a function can be used and a procedure cannot:** inside SELECT, WHERE, ORDER BY and as a table in FROM / CROSS APPLY.
- **Why one helper function:** the formula is written once (fn_AircraftRiskBreakdown); the scalar score and the dashboard cannot disagree.
- **Performance note:** a scalar function runs once per row; fine for 120 aircraft. fn_SimilarIncidents scans all incidents until A8 adds indexes.
