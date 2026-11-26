/* ==========================================================================
   objects_a_A7.sql  -  BlackBox DB, Member A, task A7: incident triggers
   Run with blackboxdb selected, after schema_incident.sql and objects_a_A4.sql. Safe to run again.
   This file: trg_incident_date (edited), trg_incident_softdelete, trg_incident_audit_full, trg_crew_fatal_check,
              trg_aircraft_ground, and it DROPS the old trg_incident_audit (the full audit replaces it).
   The view trigger trg_vfull_insert is in objects_a_A7_view.sql (it needs the columns of v_incident_full).
   Error codes: 50001 / 50006 / 50007 (old date rules, unchanged), 50101 (too many fatal crew), 50102 (view insert without a cause).
   All triggers are SET-BASED: they work for one row or for many rows in one statement.
   ========================================================================== */
USE blackboxdb;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;   -- needed: Incident is used by an indexed view, so triggers must be created with these options
GO

/* ---------- old audit trigger is replaced ---------- */
DROP TRIGGER IF EXISTS dbo.trg_incident_audit;
DROP TRIGGER IF EXISTS dbo.trg_incident_softdelete;
DROP TRIGGER IF EXISTS dbo.trg_incident_audit_full;
DROP TRIGGER IF EXISTS dbo.trg_crew_fatal_check;
DROP TRIGGER IF EXISTS dbo.trg_aircraft_ground;
DROP TRIGGER IF EXISTS dbo.trg_incident_date;
GO

/* ---------- trg_incident_date (edited: soft-deleted rows are ignored) ---------- */
-- What: blocks bad incident dates (future, before the aircraft was built, after its investigation started).
-- Why:  same rules as before; now rows with is_deleted = 1 are skipped, so an old deleted row can never block a later update.
-- Who:  Member A
CREATE TRIGGER dbo.trg_incident_date ON dbo.Incident AFTER INSERT, UPDATE AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS (SELECT 1 FROM inserted WHERE is_deleted = 0 AND incident_date > CAST(GETDATE() AS DATE))
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50001, 'Incident date cannot be in the future', 1;
  END
  IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
             WHERE i.is_deleted = 0 AND YEAR(i.incident_date) < a.year_built)
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50006, 'Incident date is before the aircraft was built', 1;
  END
  -- Investigation belongs to Member B's file; the check is skipped while that table does not exist
  IF OBJECT_ID(N'dbo.Investigation', N'U') IS NOT NULL
  BEGIN
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.Investigation v ON v.incident_id = i.incident_id
               WHERE i.is_deleted = 0 AND v.start_date < i.incident_date)
    BEGIN
      ROLLBACK TRANSACTION;
      THROW 50007, 'Incident date cannot be after its investigation started', 1;
    END
  END
END;
GO

/* ---------- trg_incident_softdelete ---------- */
-- What: turns DELETE on Incident into "mark as deleted" (is_deleted = 1, deleted_at = now); the real row stays.
-- Why:  an INSTEAD OF trigger replaces the DELETE, so history, audit and investigations are never lost, and it works for many rows.
--       Only Incident has this trigger; the child tables (weather, causes, crew) stay because the parent row stays.
-- Who:  Member A
CREATE TRIGGER dbo.trg_incident_softdelete ON dbo.Incident INSTEAD OF DELETE AS
BEGIN
  SET NOCOUNT ON;
  UPDATE i
     SET i.is_deleted = 1, i.deleted_at = SYSDATETIME()
    FROM dbo.Incident i
    JOIN deleted d ON d.incident_id = i.incident_id
   WHERE i.is_deleted = 0;
END;
GO

/* ---------- trg_incident_audit_full ---------- */
-- What: writes the history of Incident into Audit_Log: one row for an INSERT, one row per CHANGED column for an UPDATE
--       (severity, status, fatalities, injuries, location, phase_of_flight, is_deleted), with old and new value.
-- Why:  IF UPDATE(col) skips columns that were not in the SET list; joining inserted with deleted and comparing values writes a row only
--       for columns that really changed. is_deleted going 0 -> 1 is logged as action 'DELETE'. User name = SESSION_CONTEXT('app_user').
-- Who:  Member A
CREATE TRIGGER dbo.trg_incident_audit_full ON dbo.Incident AFTER INSERT, UPDATE AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @user VARCHAR(100) = COALESCE(CAST(SESSION_CONTEXT(N'app_user') AS VARCHAR(100)), SUSER_SNAME());

  IF NOT EXISTS (SELECT 1 FROM deleted)            -- INSERT: nothing in deleted
  BEGIN
    INSERT INTO dbo.Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
    SELECT 'Incident', i.incident_id, 'INSERT', NULL, NULL,
           LEFT(CONCAT('severity=', i.severity, ', status=', i.status, ', date=', CONVERT(CHAR(10), i.incident_date, 120),
                       ', location=', i.location), 500),
           @user
    FROM inserted i;
    RETURN;
  END

  -- UPDATE: all seven audited columns are NOT NULL, so <> is safe here
  IF UPDATE(severity)
    INSERT INTO dbo.Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
    SELECT 'Incident', i.incident_id, 'UPDATE', 'severity', d.severity, i.severity, @user
    FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id WHERE d.severity <> i.severity;

  IF UPDATE(status)
    INSERT INTO dbo.Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
    SELECT 'Incident', i.incident_id, 'UPDATE', 'status', d.status, i.status, @user
    FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id WHERE d.status <> i.status;

  IF UPDATE(fatalities)
    INSERT INTO dbo.Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
    SELECT 'Incident', i.incident_id, 'UPDATE', 'fatalities', CAST(d.fatalities AS VARCHAR(500)), CAST(i.fatalities AS VARCHAR(500)), @user
    FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id WHERE d.fatalities <> i.fatalities;

  IF UPDATE(injuries)
    INSERT INTO dbo.Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
    SELECT 'Incident', i.incident_id, 'UPDATE', 'injuries', CAST(d.injuries AS VARCHAR(500)), CAST(i.injuries AS VARCHAR(500)), @user
    FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id WHERE d.injuries <> i.injuries;

  IF UPDATE(location)
    INSERT INTO dbo.Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
    SELECT 'Incident', i.incident_id, 'UPDATE', 'location', d.location, i.location, @user
    FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id WHERE d.location <> i.location;

  IF UPDATE(phase_of_flight)
    INSERT INTO dbo.Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
    SELECT 'Incident', i.incident_id, 'UPDATE', 'phase_of_flight', d.phase_of_flight, i.phase_of_flight, @user
    FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id WHERE d.phase_of_flight <> i.phase_of_flight;

  IF UPDATE(is_deleted)
    INSERT INTO dbo.Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
    SELECT 'Incident', i.incident_id, CASE WHEN i.is_deleted = 1 THEN 'DELETE' ELSE 'UPDATE' END, 'is_deleted',
           CAST(d.is_deleted AS VARCHAR(5)), CAST(i.is_deleted AS VARCHAR(5)), @user
    FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id WHERE d.is_deleted <> i.is_deleted;
END;
GO

/* ---------- trg_crew_fatal_check ---------- */
-- What: an incident cannot have more crew marked 'Fatal' than its number of fatalities.
-- Why:  a rule that spans two tables (Incident_Crew and Incident) which a CHECK constraint cannot express. It counts per incident,
--       so one statement that touches crew of many incidents is checked correctly. ROLLBACK + THROW 50101 undoes everything.
-- Who:  Member A
CREATE TRIGGER dbo.trg_crew_fatal_check ON dbo.Incident_Crew AFTER INSERT, UPDATE AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS (
    SELECT 1
    FROM (SELECT DISTINCT incident_id FROM inserted) x
    JOIN dbo.Incident i ON i.incident_id = x.incident_id
    WHERE (SELECT COUNT(*) FROM dbo.Incident_Crew c
            WHERE c.incident_id = x.incident_id AND c.injury_status = 'Fatal') > i.fatalities)
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50101, 'More crew are marked Fatal than the incident has fatalities', 1;
  END
END;
GO

/* ---------- trg_aircraft_ground ---------- */
-- What: after a new Major or Fatal incident, an Active aircraft becomes Grounded.
-- Why:  keeps the fleet status in step with the incidents without the web app having to remember it; one UPDATE covers many new rows.
--       Only Active aircraft change (Retired stays Retired, an already Grounded one is left alone).
-- Who:  Member A
CREATE TRIGGER dbo.trg_aircraft_ground ON dbo.Incident AFTER INSERT AS
BEGIN
  SET NOCOUNT ON;
  UPDATE a
     SET a.status = 'Grounded'
    FROM dbo.Aircraft a
   WHERE a.status = 'Active'
     AND a.aircraft_id IN (SELECT aircraft_id FROM inserted WHERE severity IN ('Major', 'Fatal') AND is_deleted = 0);
END;
GO
PRINT 'A7 triggers created (now run objects_a_A7_view.sql for trg_vfull_insert).';
GO
