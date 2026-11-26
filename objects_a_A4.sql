/* ============================================================================
   objects_a_A4.sql  -  A4: Incident stored procedures (Member A)
   Run with your BlackBox database selected. Safe to run again.
   Needs SQL Server 2016 SP1+ (CREATE OR ALTER).
   Error codes used here: 50110 to 50115 (A range is 50100 to 50199;
   50101 to 50105 are kept for the A7 triggers).
     50110 incident has no cause
     50111 incident must have exactly one primary cause
     50112 sort value not allowed (whitelist)
     50113 page / page_size out of range
     50114 bad year range
     50115 older_than_years must be 1 or more
   ============================================================================ */
   USE blackboxdb;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---- Table types (used as table-valued parameters) ---------------------- */
IF TYPE_ID(N'dbo.CauseList') IS NULL
    CREATE TYPE dbo.CauseList AS TABLE
    (   cause_id   INT NOT NULL,
        is_primary BIT NOT NULL );
GO
IF TYPE_ID(N'dbo.CrewList') IS NULL
    CREATE TYPE dbo.CrewList AS TABLE
    (   crew_id        INT         NOT NULL,
        role_on_flight VARCHAR(40) NOT NULL,
        injury_status  VARCHAR(10) NOT NULL );
GO

/* ---- 1. sp_AddIncident --------------------------------------------------
   Incident + causes + weather + crew in ONE transaction.
   XACT_ABORT ON: any run-time error dooms the transaction, so nothing is
   left half-saved. THROW (not RAISERROR) re-raises the original error.   */
CREATE OR ALTER PROCEDURE dbo.sp_AddIncident
    @aircraft_id     INT,
    @incident_date   DATE,
    @location        VARCHAR(255),
    @airport_id      INT           = NULL,
    @flight_id       INT           = NULL,
    @phase_of_flight VARCHAR(30),
    @severity        VARCHAR(10),
    @fatalities      INT           = 0,
    @injuries        INT           = 0,
    @passengers      SMALLINT      = NULL,
    @description     VARCHAR(1000) = NULL,
    @recorded_by     VARCHAR(100)  = NULL,
    @causes          dbo.CauseList READONLY,
    @crew            dbo.CrewList  READONLY,
    @condition_type  VARCHAR(30)   = NULL,   -- NULL = no weather row
    @visibility_km   DECIMAL(6,2)  = NULL,
    @wind_speed_kmh  INT           = NULL,
    @temperature_c   INT           = NULL,
    @new_id          INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;

        IF NOT EXISTS (SELECT 1 FROM @causes)
            THROW 50110, 'An incident needs at least one cause.', 1;
        IF (SELECT COUNT(*) FROM @causes WHERE is_primary = 1) <> 1
            THROW 50111, 'An incident needs exactly one primary cause.', 1;

        INSERT INTO dbo.Incident
            (aircraft_id, incident_date, location, airport_id, flight_id,
             phase_of_flight, severity, fatalities, injuries,
             passengers_on_board, description, recorded_by)
        VALUES
            (@aircraft_id, @incident_date, @location, @airport_id, @flight_id,
             @phase_of_flight, @severity, @fatalities, @injuries,
             @passengers, @description, @recorded_by);

        SET @new_id = CAST(SCOPE_IDENTITY() AS INT);

        INSERT INTO dbo.Incident_Cause (incident_id, cause_id, is_primary)
        SELECT @new_id, cause_id, is_primary FROM @causes;

        IF @condition_type IS NOT NULL
            INSERT INTO dbo.Weather_Condition
                (incident_id, condition_type, visibility_km, wind_speed_kmh, temperature_c)
            VALUES (@new_id, @condition_type, @visibility_km, @wind_speed_kmh, @temperature_c);

        INSERT INTO dbo.Incident_Crew (incident_id, crew_id, role_on_flight, injury_status)
        SELECT @new_id, crew_id, role_on_flight, injury_status FROM @crew;

        COMMIT;
    END TRY
    BEGIN CATCH
        SET @new_id = NULL;
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

/* ---- 2. sp_UpdateIncident -----------------------------------------------
   Optimistic concurrency: the UPDATE only matches if row_ver is still the
   value the user loaded. Returns 0 = saved, -1 = changed by someone else
   (or the record no longer exists).                                       */
CREATE OR ALTER PROCEDURE dbo.sp_UpdateIncident
    @incident_id     INT,
    @aircraft_id     INT,
    @incident_date   DATE,
    @location        VARCHAR(255),
    @airport_id      INT           = NULL,
    @flight_id       INT           = NULL,
    @phase_of_flight VARCHAR(30),
    @severity        VARCHAR(10),
    @fatalities      INT           = 0,
    @injuries        INT           = 0,
    @passengers      SMALLINT      = NULL,
    @description     VARCHAR(1000) = NULL,
    @row_ver         BINARY(8)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Incident
       SET aircraft_id         = @aircraft_id,
           incident_date       = @incident_date,
           location            = @location,
           airport_id          = @airport_id,
           flight_id           = @flight_id,
           phase_of_flight     = @phase_of_flight,
           severity            = @severity,
           fatalities          = @fatalities,
           injuries            = @injuries,
           passengers_on_board = @passengers,
           description         = @description
     WHERE incident_id = @incident_id
       AND row_ver     = @row_ver
       AND is_deleted  = 0;

    IF @@ROWCOUNT = 0
        RETURN -1;      -- app shows: "This record was changed by another user, reload"
    RETURN 0;
END
GO

/* ---- 3. sp_SearchIncidents ----------------------------------------------
   Only the filters that were given are added to the SQL string. User values
   always travel as sp_executesql PARAMETERS, never inside the string.
   The ONLY text pasted into the string is the ORDER BY, chosen from a
   whitelist, so SQL injection is not possible.
   Before A8 the text search uses LIKE; after A8 swap it for CONTAINS.     */
CREATE OR ALTER PROCEDURE dbo.sp_SearchIncidents
    @text            NVARCHAR(100) = NULL,
    @airline_id      INT           = NULL,
    @type_id         INT           = NULL,
    @cause_id        INT           = NULL,
    @severity        VARCHAR(10)   = NULL,
    @from_date       DATE          = NULL,
    @to_date         DATE          = NULL,
    @airport_id      INT           = NULL,
    @user_airline_id INT           = NULL,   -- NULL unless the user has the Airline role
    @page            INT           = 1,
    @page_size       INT           = 25,
    @sort            VARCHAR(20)   = 'date_desc',
    @total           INT           = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @page < 1 OR @page_size < 1 OR @page_size > 200
        THROW 50113, 'Page must be 1 or more and page size between 1 and 200.', 1;

    -- whitelist: the value is mapped to a fixed string we wrote ourselves
    DECLARE @order NVARCHAR(200) = CASE @sort
        WHEN 'date_desc'  THEN N'i.incident_date DESC, i.incident_id DESC'
        WHEN 'date_asc'   THEN N'i.incident_date ASC, i.incident_id ASC'
        WHEN 'severity'   THEN N'CASE i.severity WHEN ''Fatal'' THEN 4 WHEN ''Major'' THEN 3 WHEN ''Serious'' THEN 2 ELSE 1 END DESC, i.incident_date DESC, i.incident_id DESC'
        WHEN 'fatalities' THEN N'i.fatalities DESC, i.incident_date DESC, i.incident_id DESC'
        END;
    IF @order IS NULL
        THROW 50112, 'Sort value not allowed.', 1;

    DECLARE @from  NVARCHAR(MAX) = N'
        FROM dbo.Incident i
        JOIN dbo.Aircraft      a  ON a.aircraft_id = i.aircraft_id
        JOIN dbo.Airline       al ON al.airline_id = a.airline_id
        JOIN dbo.Aircraft_Type t  ON t.type_id     = a.type_id';
    DECLARE @where NVARCHAR(MAX) = N' WHERE i.is_deleted = 0 AND i.is_archived = 0';

    DECLARE @like NVARCHAR(110) = NULL;
    IF @text IS NOT NULL AND LEN(LTRIM(RTRIM(@text))) > 0
    BEGIN
        SET @like  = N'%' + LTRIM(RTRIM(@text)) + N'%';
        SET @where += N' AND (i.description LIKE @p_like OR i.location LIKE @p_like OR a.registration_no LIKE @p_like)';
    END
    IF @airline_id      IS NOT NULL SET @where += N' AND a.airline_id = @p_airline';
    IF @type_id         IS NOT NULL SET @where += N' AND a.type_id = @p_type';
    IF @cause_id        IS NOT NULL SET @where += N' AND EXISTS (SELECT 1 FROM dbo.Incident_Cause ic WHERE ic.incident_id = i.incident_id AND ic.cause_id = @p_cause)';
    IF @severity        IS NOT NULL SET @where += N' AND i.severity = @p_sev';
    IF @from_date       IS NOT NULL SET @where += N' AND i.incident_date >= @p_from';
    IF @to_date         IS NOT NULL SET @where += N' AND i.incident_date <= @p_to';
    IF @airport_id      IS NOT NULL SET @where += N' AND i.airport_id = @p_airport';
    IF @user_airline_id IS NOT NULL SET @where += N' AND a.airline_id = @p_user_airline';

    DECLARE @defs NVARCHAR(MAX) = N'@p_like NVARCHAR(110), @p_airline INT, @p_type INT, @p_cause INT,
        @p_sev VARCHAR(10), @p_from DATE, @p_to DATE, @p_airport INT, @p_user_airline INT,
        @p_off INT, @p_size INT, @p_total INT OUTPUT';
    DECLARE @off INT = (@page - 1) * @page_size;

    -- 1) total number of matching rows (for the pager)
    DECLARE @sql NVARCHAR(MAX) = N'SELECT @p_total = COUNT(*)' + @from + @where;
    EXEC sys.sp_executesql @sql, @defs,
         @p_like = @like, @p_airline = @airline_id, @p_type = @type_id, @p_cause = @cause_id,
         @p_sev = @severity, @p_from = @from_date, @p_to = @to_date, @p_airport = @airport_id,
         @p_user_airline = @user_airline_id, @p_off = @off, @p_size = @page_size,
         @p_total = @total OUTPUT;

    -- 2) one page of rows
    SET @sql = N'SELECT i.incident_id, i.incident_date, i.location, i.phase_of_flight,
                        i.severity, i.fatalities, i.injuries, i.status,
                        a.registration_no AS registration, al.airline_id, al.name AS airline,
                        t.model'
             + @from + @where
             + N' ORDER BY ' + @order
             + N' OFFSET @p_off ROWS FETCH NEXT @p_size ROWS ONLY';
    EXEC sys.sp_executesql @sql, @defs,
         @p_like = @like, @p_airline = @airline_id, @p_type = @type_id, @p_cause = @cause_id,
         @p_sev = @severity, @p_from = @from_date, @p_to = @to_date, @p_airport = @airport_id,
         @p_user_airline = @user_airline_id, @p_off = @off, @p_size = @page_size,
         @p_total = @total OUTPUT;
END
GO

/* ---- 4. sp_YearlyStats --------------------------------------------------
   Temp table #stats, then PIVOT severity into columns: one row per year.
   Archived incidents ARE counted (history); deleted ones are not.         */
CREATE OR ALTER PROCEDURE dbo.sp_YearlyStats
    @from_year INT = 1995,
    @to_year   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @to_year IS NULL SET @to_year = YEAR(GETDATE());
    IF @from_year > @to_year
        THROW 50114, 'from_year must not be after to_year.', 1;

    CREATE TABLE #stats (yr INT NOT NULL, severity VARCHAR(10) NOT NULL, n INT NOT NULL);

    INSERT INTO #stats (yr, severity, n)
    SELECT YEAR(incident_date), severity, COUNT(*)
      FROM dbo.Incident
     WHERE is_deleted = 0
       AND YEAR(incident_date) BETWEEN @from_year AND @to_year
     GROUP BY YEAR(incident_date), severity;

    SELECT yr AS incident_year,
           ISNULL([Minor],   0) AS Minor,
           ISNULL([Serious], 0) AS Serious,
           ISNULL([Major],   0) AS Major,
           ISNULL([Fatal],   0) AS Fatal,
           ISNULL([Minor],0) + ISNULL([Serious],0) + ISNULL([Major],0) + ISNULL([Fatal],0) AS Total
      FROM #stats
     PIVOT (SUM(n) FOR severity IN ([Minor], [Serious], [Major], [Fatal])) AS p
     ORDER BY yr;
END
GO

/* ---- 5. sp_ArchiveOldIncidents ------------------------------------------
   Marks Closed incidents older than the limit as archived, 500 rows at a
   time. A SAVE TRAN before each batch means a failing batch is undone
   without losing the batches already done. XACT_ABORT is left OFF on
   purpose: with it ON a failure dooms the whole transaction and a
   savepoint rollback would not be possible.
   If the caller already has a transaction, we join it and do not commit.  */
CREATE OR ALTER PROCEDURE dbo.sp_ArchiveOldIncidents
    @older_than_years INT = 15,
    @moved            INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @older_than_years < 1
        THROW 50115, 'older_than_years must be 1 or more.', 1;

    DECLARE @cutoff DATE = DATEADD(YEAR, -@older_than_years, CAST(GETDATE() AS DATE));
    DECLARE @batch INT, @own BIT = 0;
    SET @moved = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRAN;
        SET @own = 1;
    END

    BEGIN TRY
        WHILE 1 = 1
        BEGIN
            SAVE TRAN archive_batch;

            UPDATE TOP (500) dbo.Incident
               SET is_archived = 1
             WHERE is_archived = 0 AND is_deleted = 0
               AND status = 'Closed'
               AND incident_date < @cutoff;

            SET @batch = @@ROWCOUNT;
            IF @batch = 0 BREAK;
            SET @moved += @batch;
        END
        IF @own = 1 COMMIT;
    END TRY
        BEGIN CATCH
        IF XACT_STATE() = 1
        BEGIN
            ROLLBACK TRAN archive_batch;      -- undo only the failing batch
            IF @own = 1 COMMIT;               -- keep the finished batches
        END;
        ELSE IF XACT_STATE() = -1
        BEGIN
            ROLLBACK;
            SET @moved = 0;
        END;
        THROW;
    END CATCH
    RETURN @moved;
END
GO
PRINT 'A4 objects created.';


