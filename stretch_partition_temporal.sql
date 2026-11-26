/* ============================================================================
   stretch_partition_temporal.sql  -  A14: Partitioning & Temporal Tables (Member A)
   Run with blackboxdb selected. Safe to run again.
   Turn on Query > Include Actual Execution Plan (Ctrl+M) to see Partition
   Elimination on the 2017 query!
   ============================================================================ */
USE blackboxdb;
GO
SET NOCOUNT ON;

/* ============================================================================
   PART 1: DATE PARTITIONING on copy table dbo.Incident_Part
   ============================================================================ */
DROP TABLE IF EXISTS dbo.Incident_Part;
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'ps_year')
    DROP PARTITION SCHEME ps_year;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pf_year')
    DROP PARTITION FUNCTION pf_year;
GO

-- 6 partitions: (<2000), [2000..2004], [2005..2009], [2010..2014], [2015..2019], [>=2020]
CREATE PARTITION FUNCTION pf_year (DATE)
AS RANGE RIGHT FOR VALUES ('2000-01-01', '2005-01-01', '2010-01-01', '2015-01-01', '2020-01-01');
GO

CREATE PARTITION SCHEME ps_year
AS PARTITION pf_year ALL TO ([PRIMARY]);
GO

CREATE TABLE dbo.Incident_Part (
    incident_id   INT          NOT NULL,
    incident_date DATE         NOT NULL,
    severity      VARCHAR(10)  NOT NULL,
    location      VARCHAR(255) NOT NULL,
    fatalities    INT          NOT NULL,
    CONSTRAINT pk_incident_part PRIMARY KEY CLUSTERED (incident_date, incident_id)
) ON ps_year(incident_date);
GO

INSERT INTO dbo.Incident_Part (incident_id, incident_date, severity, location, fatalities)
SELECT incident_id, incident_date, severity, location, fatalities
  FROM dbo.Incident
 WHERE is_deleted = 0;
GO

-- Row counts per partition (shows all 6 buckets)
SELECT $PARTITION.pf_year(incident_date) AS partition_no,
       MIN(incident_date)                AS min_date,
       MAX(incident_date)                AS max_date,
       COUNT(*)                          AS row_count
  FROM dbo.Incident_Part
 GROUP BY $PARTITION.pf_year(incident_date)
 ORDER BY partition_no;
GO

-- Partition elimination test (Ctrl+M -> Clustered Index Seek -> Actual Partition Count = 1)
SELECT COUNT(*) AS incidents_2017, SUM(fatalities) AS fatalities_2017
  FROM dbo.Incident_Part
 WHERE incident_date >= '2017-01-01' AND incident_date < '2018-01-01';
GO


/* ============================================================================
   PART 2: SYSTEM-VERSIONED TEMPORAL TABLE on dbo.Aircraft
   ============================================================================ */
IF OBJECTPROPERTY(OBJECT_ID('dbo.Aircraft'), 'TableTemporalType') <> 2
BEGIN
    ALTER TABLE dbo.Aircraft ADD
        valid_from DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
            CONSTRAINT df_aircraft_valid_from DEFAULT SYSUTCDATETIME(),
        valid_to   DATETIME2 GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL
            CONSTRAINT df_aircraft_valid_to   DEFAULT CONVERT(DATETIME2, '9999-12-31 23:59:59.9999999'),
        PERIOD FOR SYSTEM_TIME (valid_from, valid_to);

    ALTER TABLE dbo.Aircraft
        SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.Aircraft_History));
END;
GO

-- Demo: change Aircraft 1 status, wait 1s, restore original status, then query history
DECLARE @orig_status VARCHAR(10) = (SELECT status FROM dbo.Aircraft WHERE aircraft_id = 1);
DECLARE @t_before DATETIME2 = SYSUTCDATETIME();
WAITFOR DELAY '00:00:01';

UPDATE dbo.Aircraft
   SET status = CASE WHEN @orig_status = 'Active' THEN 'Grounded' ELSE 'Active' END
 WHERE aircraft_id = 1;

DECLARE @t_mid DATETIME2 = SYSUTCDATETIME();
WAITFOR DELAY '00:00:01';

UPDATE dbo.Aircraft
   SET status = @orig_status
 WHERE aircraft_id = 1;

-- 1) AS OF: what status did Aircraft 1 have at @t_mid?
SELECT aircraft_id, registration_no, status, valid_from, valid_to
  FROM dbo.Aircraft FOR SYSTEM_TIME AS OF @t_mid
 WHERE aircraft_id = 1;

DECLARE @t_after DATETIME2 = SYSUTCDATETIME();

-- 2) BETWEEN: all versions active between @t_before and @t_after
SELECT aircraft_id, registration_no, status, valid_from, valid_to
  FROM dbo.Aircraft FOR SYSTEM_TIME BETWEEN @t_before AND @t_after
 WHERE aircraft_id = 1
 ORDER BY valid_from;

-- 3) ALL: complete current + history timeline for Aircraft 1
SELECT aircraft_id, registration_no, status, valid_from, valid_to
  FROM dbo.Aircraft FOR SYSTEM_TIME ALL
 WHERE aircraft_id = 1
 ORDER BY valid_from;
GO

PRINT 'A14 partitioning and temporal table demo complete.';
GO
