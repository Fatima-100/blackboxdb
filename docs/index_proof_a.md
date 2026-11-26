# index_proof_a.md - indexes and proof (Member A, task A8)

Machine: SQL Server Express (SQLEXPRESS, version 17.0.1000), Windows laptop, SSMS
Data: 10,000 incidents, about 30,000 crew rows, about 15,000 cause rows (from seed_a.py, fixed random seed)
Full-text installed: 0 (no): `SELECT FULLTEXTSERVICEPROPERTY('IsFullTextInstalled');` returned 0

## 1. Numbers (paste the `markdown_row` column of A8_proof.sql under this header)
| Query | Index | Reads before | Reads after | ms before | ms after |
|---|---|---|---|---|---|
| Fatalities in one quarter (date range) | ix_incident_date | 243 | 11 | 7.00 | 0.00 |
| Count of Fatal incidents that are Open (dashboard filter) | ix_incident_sev_status | 355 | 11 | 4.01 | 0.00 |
| Prefix search: location LIKE 'Cape%' | ix_incident_location | 355 | 11 | 6.00 | 0.00 |
| Incidents of one cause (reverse side of the foreign key) | ix_incidentcause_cause | 69 | 14 | 4.01 | 1.00 |
| Incidents of one crew member (reverse side of the foreign key) | ix_incidentcrew_crew | 224 | 11 | 5.00 | 0.00 |
| Big GROUP BY report (year, severity), columnstore bonus | ncci_incident | 355 | 32 | 10.01 | 7.77 |
| Risk of every aircraft (v_aircraft_risk, extra index for the A6 fix) | ix_incident_aircraft | 22284 | 1676 | 77.15 | 22.93 |
| Index that does NOT help: is_deleted = 0 matches almost every row | ix_incident_isdeleted | 355 | 355 | 4.99 | 6.00 |

Plan operator before and after (fill in from the screenshots):
| # | Operator before | Operator after |
|---|---|---|
| 1 ix_incident_date | Clustered Index Scan | Index Seek |
| 2 ix_incident_sev_status | Clustered Index Scan | Index Seek |
| 3 ix_incident_location | Clustered Index Scan | Index Seek (LIKE 'Cape%'); LIKE '%Cape%' stays an Index Scan |
| 4 ix_incidentcause_cause | Clustered Index Scan | Index Seek |
| 5 ix_incidentcrew_crew | Clustered Index Scan | Index Seek |
| 6 full-text | not tested: full-text is not installed on this Express server | n/a (search keeps LIKE) |
| 7 columnstore (bonus) | Clustered Index Scan | Columnstore Index Scan |
| 8 ix_incident_aircraft (A6 fix) | Clustered Index Scan | Index Seek / Scan on the covering index (no key lookups) |

## 2. Screenshots (one before and one after per query)
For each query: Query menu > Include Actual Execution Plan, run with `SET STATISTICS IO ON; SET STATISTICS TIME ON;`, then save the plan picture and the
Messages tab. To get the "before" picture, drop the index first (`DROP INDEX ... ON ...`), and create it again for the "after" picture
(the CREATE statements are in objects_a_A8_indexes.sql). Name the files `A8_q1_before.png`, `A8_q1_after.png`, and so on.
The five queries are in the `#q` list at the top of A8_proof.sql.

Extra picture for the viva (key lookup): with ix_incident_date in place run
`SELECT incident_id, incident_date, description FROM dbo.Incident WHERE incident_date BETWEEN '2019-01-01' AND '2019-01-31';`
The plan shows Index Seek plus Key Lookup, because description is not in the index. Then run it with `SELECT incident_id, incident_date` only: no lookup.

## 3. The index that does not help
`ix_incident_isdeleted ON Incident(is_deleted)`. Test 9 in A8_proof.sql: `WHERE is_deleted = 0` matches almost every row, so the index is not selective.
SQL Server ignores it (reads before = reads after) because reading 10,000 index entries and then looking up 10,000 rows one by one in the table costs MORE than one
sequential scan of the table. Forced with `WITH (INDEX(ix_incident_isdeleted))` the query needs about 21,000 reads (Index Seek + Key Lookups) against 355 for the scan: about 60 times worse (screenshots A8_q7_ignored.png and A8_q7_forced.png).
(`WHERE is_deleted = 1` matches only a few rows, and there the index would be used; the optimizer decides by how many rows match, not by the column.)

## 4. The cost test (A8_write_cost.sql)
| Scenario | Average ms for 10,000 inserts |
|---|---|
| A: primary key only | 81.7 |
| B: 6 extra indexes | 538.0 |
Times slower with indexes: 6.58
Meaning: every index must be updated on every INSERT, UPDATE of an indexed column and DELETE. Read-heavy tables (reports) need many indexes, write-heavy tables few.

## 5. If full-text is not installed
Full-text search is not installed on this SQL Server Express edition (IsFullTextInstalled = 0). The search uses LIKE; objects_a_A8_indexes.sql
creates the full-text index automatically when the feature exists. Test 6 is skipped by the script.

Note: the columnstore index needed free memory to build on Express (one build hit Msg 8645, a memory timeout, and succeeded after clearing caches); `WITH (MAXDOP = 1)` lowers the memory needed.

## 6. Viva answers
- **Clustered vs nonclustered:** a clustered index IS the table (rows stored in key order, one per table: the primary key here). A nonclustered index is a separate sorted
  structure with a pointer back to the row; a table can have many.
- **Seek vs scan:** a seek jumps to the matching key range using the B-tree; a scan reads every row or page.
- **Covering index and INCLUDE:** a query is covered when the index holds every column it needs, so no lookup into the table is needed. INCLUDE columns are stored only
  in the leaf level (not in the sort key), so the index stays small.
- **Key lookup:** when the index finds the row but the query needs a column that is not in the index, SQL Server fetches the row from the clustered index, one lookup per row.
  Many lookups can cost more than a scan, so the optimizer switches to a scan when many rows match.
- **Selectivity:** the fraction of rows a filter returns. Indexes help for low fractions (a few rows) and not for high ones (is_deleted = 0).
- **Leftmost prefix:** ix_incident_sev_status helps WHERE severity = ... and WHERE severity = ... AND status = ..., but not WHERE status = ... alone.
- **Why LIKE '%word%' cannot seek:** the index is sorted from the first letter; with a leading % there is no starting point. That is why full-text exists.
- **Why too many indexes hurt:** more disk, more memory, and every write updates all of them (section 4).
- **Columnstore:** data stored by column and compressed; very good for GROUP BY / SUM over many rows, not for single-row lookups.
