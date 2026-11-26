/* ============================================================================
   objects_a_A13.sql  -  A13: Enhanced sp_SearchIncidents for /search (Member A)
   Run with blackboxdb selected. Safe to run again (CREATE OR ALTER).
   Adds:
     1) Multi-severity filter via STRING_SPLIT(@severity, ',')
     2) i.description in the result set so /search can highlight matched words
   ============================================================================ */
USE blackboxdb;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- What: dynamic parameterized search across incidents with paging, sort whitelist, and multi-severity filter.
-- Why:  feeds both A11 (/api/incidents) and A13 (/search), returning description for search-word highlighting
--       while keeping all user input in sp_executesql parameters (no SQL injection).
-- Who:  Member A
CREATE OR ALTER PROCEDURE dbo.sp_SearchIncidents
    @text            NVARCHAR(100) = NULL,
    @airline_id      INT           = NULL,
    @type_id         INT           = NULL,
    @cause_id        INT           = NULL,
    @severity        VARCHAR(100)  = NULL,   -- single ('Fatal') or comma-separated ('Fatal,Major')
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
    IF @severity        IS NOT NULL AND LEN(LTRIM(RTRIM(@severity))) > 0
        SET @where += N' AND i.severity IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@p_sev, '',''))';
    IF @from_date       IS NOT NULL SET @where += N' AND i.incident_date >= @p_from';
    IF @to_date         IS NOT NULL SET @where += N' AND i.incident_date <= @p_to';
    IF @airport_id      IS NOT NULL SET @where += N' AND i.airport_id = @p_airport';
    IF @user_airline_id IS NOT NULL SET @where += N' AND a.airline_id = @p_user_airline';

    DECLARE @defs NVARCHAR(MAX) = N'@p_like NVARCHAR(110), @p_airline INT, @p_type INT, @p_cause INT,
        @p_sev VARCHAR(100), @p_from DATE, @p_to DATE, @p_airport INT, @p_user_airline INT,
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
                        i.severity, i.fatalities, i.injuries, i.status, i.description,
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
PRINT 'A13 sp_SearchIncidents updated.';
GO
