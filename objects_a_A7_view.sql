/* ==========================================================================
   objects_a_A7_view.sql  -  A7: trg_vfull_insert (INSTEAD OF INSERT on v_incident_full)
   Needs v_incident_full from A5. Step 0 below checks that the view has the columns this trigger reads.
   If columns are missing, the script prints which ones and skips everything else (nothing is changed).
   ========================================================================== */
USE blackboxdb;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/* ---- Step 0: check the view columns ---- */
DECLARE @missing NVARCHAR(500);
SELECT @missing = STRING_AGG(c.col, ', ')
FROM (VALUES ('aircraft_id'), ('airport_id'), ('flight_id'), ('incident_date'), ('location'), ('phase_of_flight'),
             ('severity'), ('fatalities'), ('injuries'), ('passengers_on_board'), ('description'), ('primary_cause_id')) c(col)
WHERE COL_LENGTH(N'dbo.v_incident_full', c.col) IS NULL;
IF OBJECT_ID(N'dbo.v_incident_full', N'V') IS NULL
BEGIN
  PRINT 'v_incident_full does not exist. Run the A5 views first. Nothing was changed.';
  SET NOEXEC ON;
END
ELSE IF @missing IS NOT NULL
BEGIN
  PRINT 'v_incident_full is missing these columns: ' + @missing + '. Nothing was changed. Send me the output of EXEC sp_helptext ''v_incident_full''.';
  SET NOEXEC ON;
END
GO

DROP TRIGGER IF EXISTS dbo.trg_vfull_insert;
GO
-- What: lets you INSERT into the join view v_incident_full; the trigger writes the Incident rows and their primary-cause rows.
-- Why:  a join view cannot be inserted into directly, so INSTEAD OF INSERT takes the new rows from "inserted" and does the real work.
--       MERGE ... ON 1 = 0 never matches, so every row is inserted, and OUTPUT ... INTO @map returns the new incident_id next to the
--       row_key of its source row, which is how each new Incident is paired with ITS cause (a plain INSERT cannot return the source key).
--       The trigger runs inside the transaction of the INSERT statement, so incident and cause rows succeed or fail together.
--       Each row needs primary_cause_id (error 50102). New incidents start with status Open (the column default).
-- Who:  Member A
CREATE TRIGGER dbo.trg_vfull_insert ON dbo.v_incident_full INSTEAD OF INSERT AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS (SELECT 1 FROM inserted WHERE primary_cause_id IS NULL)
  BEGIN
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW 50102, 'Every incident inserted through v_incident_full needs a primary_cause_id', 1;
  END

  DECLARE @src TABLE (row_key INT IDENTITY(1,1) PRIMARY KEY, aircraft_id INT, airport_id INT, flight_id INT, incident_date DATE,
                      location VARCHAR(120), phase_of_flight VARCHAR(20), severity VARCHAR(20), fatalities INT, injuries INT,
                      passengers_on_board SMALLINT, description VARCHAR(MAX), primary_cause_id INT);
  INSERT INTO @src(aircraft_id, airport_id, flight_id, incident_date, location, phase_of_flight, severity, fatalities, injuries,
                   passengers_on_board, description, primary_cause_id)
  SELECT aircraft_id, airport_id, flight_id, incident_date, location, phase_of_flight, severity, ISNULL(fatalities, 0), ISNULL(injuries, 0),
         passengers_on_board, description, primary_cause_id
  FROM inserted;

  DECLARE @map TABLE (incident_id INT NOT NULL, row_key INT NOT NULL);

  MERGE dbo.Incident AS tgt
  USING @src AS s ON 1 = 0
  WHEN NOT MATCHED THEN
    INSERT (aircraft_id, airport_id, flight_id, incident_date, location, phase_of_flight, severity, fatalities, injuries,
            passengers_on_board, description)
    VALUES (s.aircraft_id, s.airport_id, s.flight_id, s.incident_date, s.location, s.phase_of_flight, s.severity, s.fatalities, s.injuries,
            s.passengers_on_board, s.description)
  OUTPUT inserted.incident_id, s.row_key INTO @map(incident_id, row_key);

  INSERT INTO dbo.Incident_Cause(incident_id, cause_id, is_primary)
  SELECT m.incident_id, s.primary_cause_id, 1
  FROM @map m JOIN @src s ON s.row_key = m.row_key;
END;
GO
SET NOEXEC OFF;
GO
IF OBJECT_ID(N'dbo.trg_vfull_insert', N'TR') IS NOT NULL PRINT 'trg_vfull_insert created.';
GO
