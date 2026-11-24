# viva_notes.md - Member A

## A1. Schema, incident side (schema_incident.sql)

**One-line "why" sentences**
- Aircraft_Category / Cause_Category: the category text was repeated on every row, so it moved to lookup tables (3NF, no typos).
- Airline.iata_code: a plain UNIQUE allows only one NULL in SQL Server, so a filtered unique index (WHERE iata_code IS NOT NULL) is used.
- Airport.latitude/longitude DECIMAL(9,6): exact decimal to about 0.1 m, no rounding error like FLOAT; CHECK keeps -90..90 and -180..180.
- Incident.row_ver ROWVERSION: SQL Server changes it on every update, so two users editing the same row are detected (optimistic concurrency).
- Incident.is_deleted / is_archived: soft delete and archive keep history instead of removing rows.
- Import_Staging raw_* VARCHAR: real files are dirty; raw text is loaded first, then validated with TRY_CONVERT.
- Audit_Log PRIMARY KEY NONCLUSTERED: leaves the clustered index free for changed_at (Member B, task B7).
- Flight has two foreign keys to Airport (origin, destination): shows two relationships to one table; CHECK stops origin = destination.
- DATETIME2 instead of DATETIME: more precise and the modern type.

**Likely viva questions**
1. Why DECIMAL(9,6) for coordinates? (exact, 6 decimals about 0.1 m, 3 digits before the point for 180)
2. Why a filtered unique index? (many NULLs allowed, real values still unique)
3. Why ROWVERSION? (detects lost updates)
4. Why are the raw import columns VARCHAR? (dirty data must load first, then be checked)
5. Why move category into lookup tables? (3NF: no repeated text, one place to change a name)

**Cascade rules (agree with Member B)**: CASCADE only on Weather_Condition, Incident_Cause, Incident_Crew (and Import_Staging).
Investigation and Safety_Recommendation (Member B) should be NO ACTION.

**Message for Member B**: the old check "incident date cannot be after its investigation started" (error 50007) stays in
trg_incident_date but is skipped until the Investigation table exists.
