/* ==========================================================================
   objects_a.sql  -  BlackBox DB, Member A's views, functions, procedures, triggers, indexes.
   Run order (schema.sql): schema_incident.sql, schema_people.sql, objects_a.sql, objects_b.sql.
   Safe to run again: every object uses CREATE OR ALTER.
   Needs SQL Server 2017 or newer (CONCAT_WS).
   Sections:  A3 CSV import (fn_ImportParsed, sp_ValidateImport, sp_ImportIncidents)
   ========================================================================== */
USE blackboxdb;
GO

/* ===================== A3. REAL DATA IMPORT ===================== */

-- What: turns the raw VARCHAR staging columns of one batch into typed columns (date, number, mapped phase, severity).
-- Why:  one place holds the parsing rules, so the validation procedure and the import procedure can never disagree.
--       TRY_CONVERT / TRY_CAST return NULL on bad text instead of raising an error, so one bad row cannot stop the batch.
-- Who:  Member A
CREATE OR ALTER FUNCTION dbo.fn_ImportParsed (@batch_id INT)
RETURNS TABLE
AS
RETURN
SELECT s.stage_id, s.row_no, s.row_status,
       r.d, r.reg, r.loc, r.oper, m.mfr, m.model, q.phase, q.phase_known,
       q.fat, q.inj, r.wx,
       CASE WHEN q.fat > 0 THEN 'Fatal' WHEN q.inj >= 5 THEN 'Major' WHEN q.inj >= 1 THEN 'Serious' ELSE 'Minor' END AS sev
FROM dbo.Import_Staging AS s
CROSS APPLY (SELECT
      TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(s.raw_date)), ''), 23)                    AS d,        -- style 23 = YYYY-MM-DD
      NULLIF(LTRIM(RTRIM(s.raw_registration)), '')                                   AS reg,
      NULLIF(LTRIM(RTRIM(s.raw_location)), '')                                       AS loc,
      LEFT(COALESCE(NULLIF(LTRIM(RTRIM(s.raw_airline)), ''), 'Unknown operator'), 100) AS oper,
      NULLIF(LTRIM(RTRIM(s.raw_model)), '')                                          AS model_raw,
      LEFT(NULLIF(LTRIM(RTRIM(s.raw_weather)), ''), 40)                              AS wx,
      NULLIF(LTRIM(RTRIM(s.raw_fatalities)), '')                                     AS fat_txt,
      NULLIF(LTRIM(RTRIM(s.raw_injuries)), '')                                       AS inj_txt,
      UPPER(NULLIF(LTRIM(RTRIM(s.raw_phase)), ''))                                   AS ph_txt) AS r
CROSS APPLY (SELECT
      CASE WHEN r.fat_txt IS NULL THEN 0 ELSE TRY_CAST(r.fat_txt AS FLOAT) END       AS fat,      -- blank = 0, text = NULL (error)
      CASE WHEN r.inj_txt IS NULL THEN 0 ELSE TRY_CAST(r.inj_txt AS FLOAT) END       AS inj,
      CASE WHEN r.ph_txt IN ('TAXI', 'STANDING')                                      THEN 'Taxi'
           WHEN r.ph_txt IN ('TAKEOFF', 'TAKE-OFF', 'TAKE OFF')                       THEN 'Takeoff'
           WHEN r.ph_txt IN ('CLIMB', 'INITIAL CLIMB')                                THEN 'Climb'
           WHEN r.ph_txt IN ('CRUISE', 'EN ROUTE', 'ENROUTE', 'MANEUVERING')          THEN 'Cruise'
           WHEN r.ph_txt = 'DESCENT'                                                  THEN 'Descent'
           WHEN r.ph_txt IN ('APPROACH', 'GO-AROUND', 'GO AROUND')                    THEN 'Approach'
           WHEN r.ph_txt IN ('LANDING', 'LANDING ROLL')                               THEN 'Landing' END AS phase_map,
      (SELECT TOP 1 v.maker FROM (VALUES ('De Havilland'), ('McDonnell Douglas'), ('Hawker Beechcraft'), ('Air Tractor'),
                                         ('Aero Commander'), ('American Champion')) AS v(maker)
       WHERE r.model_raw LIKE v.maker + ' %')                                         AS multi_word_maker) AS p0
CROSS APPLY (SELECT p0.fat, p0.inj,
      COALESCE(p0.phase_map, 'Cruise')                                               AS phase,    -- unknown phase becomes Cruise
      CASE WHEN p0.phase_map IS NULL THEN 0 ELSE 1 END                               AS phase_known) AS q
CROSS APPLY (SELECT
      LEFT(CASE WHEN r.model_raw IS NULL THEN 'Unknown'
                WHEN p0.multi_word_maker IS NOT NULL THEN p0.multi_word_maker
                WHEN CHARINDEX(' ', r.model_raw) > 0 THEN LEFT(r.model_raw, CHARINDEX(' ', r.model_raw) - 1)
                ELSE 'Unknown' END, 60)                                              AS mfr,      -- first word = manufacturer
      LEFT(CASE WHEN r.model_raw IS NULL THEN 'Unknown'
                WHEN p0.multi_word_maker IS NOT NULL THEN LTRIM(SUBSTRING(r.model_raw, LEN(p0.multi_word_maker) + 1, 200))
                WHEN CHARINDEX(' ', r.model_raw) > 0 THEN LTRIM(SUBSTRING(r.model_raw, CHARINDEX(' ', r.model_raw) + 1, 200))
                ELSE r.model_raw END, 60)                                            AS model) AS m;
GO

-- What: checks every staging row of a batch and sets row_status (Valid, Warning, Error or Duplicate) and error_message.
-- Why:  the app shows this result as a preview BEFORE anything reaches the real tables. Rules: date is a real past date and not before
--       the aircraft was built (the incident trigger would reject it), registration and location present, numbers whole and not negative.
--       Duplicates (same aircraft, date, phase) are found against the Incident table and inside the file itself.
-- Who:  Member A
CREATE OR ALTER PROCEDURE dbo.sp_ValidateImport
    @batch_id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.* INTO #p FROM dbo.fn_ImportParsed(@batch_id) AS p WHERE p.row_status <> 'Imported';

    UPDATE s
    SET row_status    = CASE WHEN e.err IS NOT NULL THEN 'Error' WHEN e.warn IS NOT NULL THEN 'Warning' ELSE 'Valid' END,
        error_message = NULLIF(LEFT(CONCAT_WS('; ', e.err, e.warn), 300), '')
    FROM dbo.Import_Staging AS s
    JOIN #p AS p ON p.stage_id = s.stage_id
    OUTER APPLY (SELECT TOP 1 a.year_built FROM dbo.Aircraft AS a WHERE a.registration_no = p.reg) AS ac
    CROSS APPLY (SELECT
        NULLIF(CONCAT_WS('; ',
            CASE WHEN NULLIF(LTRIM(RTRIM(s.raw_date)), '') IS NULL THEN 'Date is missing'
                 WHEN p.d IS NULL                               THEN 'Date is not a valid YYYY-MM-DD date'
                 WHEN p.d > CAST(GETDATE() AS date)             THEN 'Date is in the future'
                 WHEN p.d < '19300101'                          THEN 'Date is before 1930'
                 WHEN ac.year_built IS NOT NULL AND YEAR(p.d) < ac.year_built THEN 'Date is before the aircraft was built' END,
            CASE WHEN p.reg IS NULL THEN 'Registration is missing'
                 WHEN LEN(p.reg) > 12 THEN 'Registration is longer than 12 characters' END,
            CASE WHEN p.loc IS NULL THEN 'Location is missing' END,
            CASE WHEN p.fat IS NULL THEN 'Fatalities is not a number'
                 WHEN p.fat < 0 THEN 'Fatalities cannot be negative'
                 WHEN p.fat <> FLOOR(p.fat) OR p.fat > 100000 THEN 'Fatalities must be a whole number' END,
            CASE WHEN p.inj IS NULL THEN 'Injuries is not a number'
                 WHEN p.inj < 0 THEN 'Injuries cannot be negative'
                 WHEN p.inj <> FLOOR(p.inj) OR p.inj > 100000 THEN 'Injuries must be a whole number' END
        ), '') AS err,
        CASE WHEN p.phase_known = 0 THEN
             CASE WHEN NULLIF(LTRIM(RTRIM(s.raw_phase)), '') IS NULL THEN 'Phase is missing, set to Cruise'
                  ELSE CONCAT('Phase "', LEFT(s.raw_phase, 30), '" not recognised, set to Cruise') END END AS warn
    ) AS e
    WHERE s.batch_id = @batch_id AND s.row_status <> 'Imported';

    -- duplicate of an incident that is already in the database (same aircraft, date and phase)
    UPDATE s
    SET row_status = 'Duplicate', error_message = 'Already in the database (same aircraft, date and phase)'
    FROM dbo.Import_Staging AS s
    JOIN #p AS p ON p.stage_id = s.stage_id
    WHERE s.row_status IN ('Valid', 'Warning')
      AND EXISTS (SELECT 1 FROM dbo.Incident AS i JOIN dbo.Aircraft AS a ON a.aircraft_id = i.aircraft_id
                  WHERE a.registration_no = p.reg AND i.incident_date = p.d AND i.phase_of_flight = p.phase);

    -- duplicate inside the same file: the first row stays, later copies are marked
    ;WITH r AS (
        SELECT s.stage_id,
               ROW_NUMBER() OVER (PARTITION BY p.reg, p.d, p.phase ORDER BY s.row_no) AS rn
        FROM dbo.Import_Staging AS s JOIN #p AS p ON p.stage_id = s.stage_id
        WHERE s.row_status IN ('Valid', 'Warning'))
    UPDATE s
    SET row_status = 'Duplicate', error_message = 'Repeated inside this file (same aircraft, date and phase)'
    FROM dbo.Import_Staging AS s JOIN r ON r.stage_id = s.stage_id
    WHERE r.rn > 1;

    UPDATE b
    SET total_rows = c.total, ok_rows = c.ok, error_rows = c.bad,
        status = CASE WHEN b.status IN ('Uploaded', 'Validated') THEN 'Validated' ELSE b.status END
    FROM dbo.Import_Batch AS b
    CROSS APPLY (SELECT COUNT(*) AS total,
                        ISNULL(SUM(CASE WHEN row_status IN ('Valid', 'Warning') THEN 1 ELSE 0 END), 0) AS ok,
                        ISNULL(SUM(CASE WHEN row_status = 'Error' THEN 1 ELSE 0 END), 0) AS bad
                 FROM dbo.Import_Staging WHERE batch_id = b.batch_id) AS c
    WHERE b.batch_id = @batch_id;
END;
GO

-- What: imports the valid rows of one batch into Airline, Aircraft_Type, Aircraft, Incident and Weather_Condition.
-- Why:  everything runs in ONE transaction (all or nothing). MERGE adds only the airlines, types and aircraft that do not exist yet and
--       OUTPUT reports which rows it added; a MERGE with ON 1 = 0 is used for Incident because OUTPUT can then return the staging
--       row id next to the new incident id (a plain INSERT cannot), which is needed to attach the weather row.
-- Who:  Member A
CREATE OR ALTER PROCEDURE dbo.sp_ImportIncidents
    @batch_id INT,
    @imported INT OUTPUT,
    @skipped  INT OUTPUT,
    @errors   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @imported = 0, @skipped = 0, @errors = 0;

    IF NOT EXISTS (SELECT 1 FROM dbo.Import_Batch WHERE batch_id = @batch_id)
        THROW 50101, 'Import batch not found', 1;

    DECLARE @cat_light INT = (SELECT category_id FROM dbo.Aircraft_Category WHERE category_name = 'Light');
    DECLARE @newAirline TABLE (airline_id INT);
    DECLARE @newType    TABLE (type_id INT);
    DECLARE @newAircraft TABLE (aircraft_id INT);
    DECLARE @map TABLE (stage_id INT PRIMARY KEY, incident_id INT);

    BEGIN TRY
        BEGIN TRAN;

        EXEC dbo.sp_ValidateImport @batch_id;                       -- always re-check right before importing

        SELECT p.* INTO #ok FROM dbo.fn_ImportParsed(@batch_id) AS p WHERE p.row_status IN ('Valid', 'Warning');

        MERGE dbo.Airline AS t
        USING (SELECT DISTINCT oper FROM #ok) AS s ON t.name = s.oper
        WHEN NOT MATCHED THEN INSERT (name, country) VALUES (s.oper, 'Unknown')
        OUTPUT inserted.airline_id INTO @newAirline;

        MERGE dbo.Aircraft_Type AS t
        USING (SELECT DISTINCT mfr, model FROM #ok) AS s ON t.manufacturer = s.mfr AND t.model = s.model
        WHEN NOT MATCHED THEN INSERT (manufacturer, model, category_id) VALUES (s.mfr, s.model, @cat_light)
        OUTPUT inserted.type_id INTO @newType;

        MERGE dbo.Aircraft AS t
        USING (SELECT x.reg, x.airline_id, x.type_id
               FROM (SELECT o.reg, al.airline_id, ty.type_id,
                            ROW_NUMBER() OVER (PARTITION BY o.reg ORDER BY o.row_no) AS rn
                     FROM #ok AS o
                     JOIN dbo.Airline AS al ON al.name = o.oper
                     JOIN dbo.Aircraft_Type AS ty ON ty.manufacturer = o.mfr AND ty.model = o.model) AS x
               WHERE x.rn = 1) AS s
           ON t.registration_no = s.reg
        WHEN NOT MATCHED THEN INSERT (registration_no, airline_id, type_id) VALUES (s.reg, s.airline_id, s.type_id)
        OUTPUT inserted.aircraft_id INTO @newAircraft;

        MERGE dbo.Incident AS t
        USING (SELECT o.stage_id, a.aircraft_id, o.d, ISNULL(LEFT(o.loc, 120), 'Unknown') AS loc, o.phase, o.sev,
                      CAST(o.fat AS INT) AS fat, CAST(o.inj AS INT) AS inj,
                      CONCAT('Imported from ', b.file_name, ', row ', o.row_no) AS descr,
                      LEFT(COALESCE(b.uploaded_by, 'import'), 100) AS who
               FROM #ok AS o
               JOIN dbo.Aircraft AS a ON a.registration_no = o.reg
               JOIN dbo.Import_Batch AS b ON b.batch_id = @batch_id
               WHERE NOT EXISTS (SELECT 1 FROM dbo.Incident AS i
                                 WHERE i.aircraft_id = a.aircraft_id AND i.incident_date = o.d AND i.phase_of_flight = o.phase)) AS s
           ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (aircraft_id, incident_date, location, phase_of_flight, severity, fatalities, injuries, status, description, recorded_by)
            VALUES (s.aircraft_id, s.d, s.loc, s.phase, s.sev, s.fat, s.inj, 'Closed', s.descr, s.who)
        OUTPUT s.stage_id, inserted.incident_id INTO @map (stage_id, incident_id);

        INSERT INTO dbo.Weather_Condition (incident_id, condition_type)
        SELECT m.incident_id, o.wx FROM @map AS m JOIN #ok AS o ON o.stage_id = m.stage_id WHERE o.wx IS NOT NULL;

        UPDATE s SET row_status = 'Imported', error_message = NULL
        FROM dbo.Import_Staging AS s JOIN @map AS m ON m.stage_id = s.stage_id;

        -- valid rows that were not inserted were duplicates (found only now)
        UPDATE s SET row_status = 'Duplicate', error_message = 'Already in the database (same aircraft, date and phase)'
        FROM dbo.Import_Staging AS s JOIN #ok AS o ON o.stage_id = s.stage_id
        WHERE s.row_status IN ('Valid', 'Warning');

        SELECT @imported = COUNT(*) FROM @map;
        SELECT @skipped = COUNT(*) FROM dbo.Import_Staging WHERE batch_id = @batch_id AND row_status = 'Duplicate';
        SELECT @errors  = COUNT(*) FROM dbo.Import_Staging WHERE batch_id = @batch_id AND row_status = 'Error';

        UPDATE dbo.Import_Batch SET ok_rows = @imported, error_rows = @errors, status = 'Imported' WHERE batch_id = @batch_id;

        INSERT INTO dbo.Audit_Log (table_name, record_id, action_type, column_name, new_value, changed_by)
        SELECT 'Import_Batch', @batch_id, 'INSERT', 'file_name',
               LEFT(CONCAT(b.file_name, ': ', @imported, ' imported, ', @skipped, ' duplicates, ', @errors, ' errors'), 500),
               COALESCE(CAST(SESSION_CONTEXT(N'app_user') AS VARCHAR(100)), SUSER_SNAME())
        FROM dbo.Import_Batch AS b WHERE b.batch_id = @batch_id;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE dbo.Import_Batch SET status = 'Failed' WHERE batch_id = @batch_id;
        SELECT @imported = 0;
        THROW;
    END CATCH
END;
GO
