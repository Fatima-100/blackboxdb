/* ==========================================================================
   schema_incident.sql  -  BlackBox DB, INCIDENT SIDE (Member A, task A1)
   Run order: 00_create_db.sql, then this file, then (later) schema_people.sql.
   Tables here: Aircraft_Category, Cause_Category, Airline, Aircraft_Type, Cause,
   Crew_Member, Airport, Aircraft, Flight, Maintenance_Record, Incident,
   Weather_Condition, Incident_Cause, Incident_Crew, Audit_Log, Import_Batch,
   Import_Staging  (17 tables).
   Tables owned by Member B (Investigator, Investigation, Safety_Recommendation,
   Users, ...) are NOT in this file.
   ========================================================================== */
USE blackboxdb;
GO

/* ---------- LOOKUP TABLES (3NF: category text moved out of Aircraft_Type and Cause) ---------- */

-- What: list of aircraft categories (Narrow-body, Turboprop, ...).
-- Why:  category text was repeated on every Aircraft_Type row; a lookup table removes the repetition (3NF) and stops typos.
-- Who:  Member A
CREATE TABLE Aircraft_Category (
  category_id   INT IDENTITY(1,1) PRIMARY KEY,
  category_name VARCHAR(30) NOT NULL UNIQUE
);

-- What: list of cause categories (Mechanical, Weather, ...).
-- Why:  same reason as Aircraft_Category; also lets reports group causes by category with a clean join.
-- Who:  Member A
CREATE TABLE Cause_Category (
  category_id   INT IDENTITY(1,1) PRIMARY KEY,
  category_name VARCHAR(40) NOT NULL UNIQUE
);

INSERT INTO Aircraft_Category(category_name) VALUES
 ('Narrow-body'),('Wide-body'),('Regional jet'),('Turboprop'),('Light');
INSERT INTO Cause_Category(category_name) VALUES
 ('Mechanical'),('Human factors'),('Environmental'),('Weather'),('Operational'),('Maintenance');
GO

/* ---------- CORE REFERENCE TABLES ---------- */

-- What: airlines that own aircraft.
-- Why:  iata_code is optional (CHAR(2) because IATA codes are always 2 letters). A plain UNIQUE allows only ONE NULL,
--       so uniqueness is a FILTERED unique index (WHERE iata_code IS NOT NULL) - many airlines may have no code.
-- Who:  Member A
CREATE TABLE Airline (
  airline_id INT IDENTITY(1,1) PRIMARY KEY,
  name       VARCHAR(100) NOT NULL UNIQUE,
  country    VARCHAR(60)  NOT NULL,
  iata_code  CHAR(2) NULL
);
CREATE UNIQUE INDEX ux_airline_iata ON Airline(iata_code) WHERE iata_code IS NOT NULL;

-- What: aircraft models (manufacturer + model + category).
-- Why:  one row per model so 120 aircraft do not repeat manufacturer/model text; category is a foreign key (3NF).
-- Who:  Member A
CREATE TABLE Aircraft_Type (
  type_id      INT IDENTITY(1,1) PRIMARY KEY,
  manufacturer VARCHAR(60) NOT NULL,
  model        VARCHAR(60) NOT NULL,
  category_id  INT NOT NULL REFERENCES Aircraft_Category(category_id),
  CONSTRAINT uq_type UNIQUE (manufacturer, model)
);

-- What: the list of possible incident causes.
-- Why:  causes are chosen from a fixed list (many-to-many with Incident), so reports can count them reliably.
-- Who:  Member A
CREATE TABLE Cause (
  cause_id    INT IDENTITY(1,1) PRIMARY KEY,
  cause_name  VARCHAR(100) NOT NULL UNIQUE,
  category_id INT NOT NULL REFERENCES Cause_Category(category_id)
);

-- What: pilots and cabin crew who can be on an incident.
-- Why:  license_no UNIQUE identifies a person; experience_years CHECK >= 0 blocks impossible values.
-- Who:  Member A
CREATE TABLE Crew_Member (
  crew_id          INT IDENTITY(1,1) PRIMARY KEY,
  name             VARCHAR(100) NOT NULL,
  role             VARCHAR(40)  NOT NULL,
  license_no       VARCHAR(30)  NOT NULL UNIQUE,
  experience_years INT NOT NULL DEFAULT 0,
  CONSTRAINT ck_crew_experience CHECK (experience_years >= 0)
);

-- What: airports with coordinates (used by the map page and by Flight and Incident).
-- Why:  DECIMAL(9,6) is exact to ~0.1 m and has no float rounding error (FLOAT would). CHAR(3)/CHAR(4) = fixed-length IATA/ICAO.
--       Both codes are optional, so uniqueness uses filtered unique indexes.
-- Who:  Member A
CREATE TABLE Airport (
  airport_id INT IDENTITY(1,1) PRIMARY KEY,
  iata_code  CHAR(3) NULL,
  icao_code  CHAR(4) NULL,
  name       VARCHAR(120) NOT NULL,
  city       VARCHAR(80)  NULL,
  country    VARCHAR(60)  NOT NULL,
  latitude   DECIMAL(9,6) NOT NULL,
  longitude  DECIMAL(9,6) NOT NULL,
  CONSTRAINT ck_airport_lat CHECK (latitude  BETWEEN -90  AND 90),
  CONSTRAINT ck_airport_lon CHECK (longitude BETWEEN -180 AND 180)
);
CREATE UNIQUE INDEX ux_airport_iata ON Airport(iata_code) WHERE iata_code IS NOT NULL;
CREATE UNIQUE INDEX ux_airport_icao ON Airport(icao_code) WHERE icao_code IS NOT NULL;

-- What: one physical aircraft (registration number, owner airline, model, build year, status).
-- Why:  SMALLINT is enough for a year; CHECK on year_built and on status keeps bad data out; status is needed for fleet reports.
-- Who:  Member A
CREATE TABLE Aircraft (
  aircraft_id     INT IDENTITY(1,1) PRIMARY KEY,
  registration_no VARCHAR(12) NOT NULL UNIQUE,
  airline_id      INT NOT NULL REFERENCES Airline(airline_id),
  type_id         INT NOT NULL REFERENCES Aircraft_Type(type_id),
  year_built      SMALLINT NULL,
  status          VARCHAR(10) NOT NULL DEFAULT 'Active',
  CONSTRAINT ck_aircraft_year   CHECK (year_built BETWEEN 1930 AND 2100),
  CONSTRAINT ck_aircraft_status CHECK (status IN ('Active','Grounded','Retired'))
);

-- What: a scheduled flight between two airports (an incident may belong to one flight).
-- Why:  gives the incident real context (route, passengers) and creates two foreign keys to the same table (Airport),
--       which is a good ERD example; CHECK stops a flight from starting and ending at the same airport.
-- Who:  Member A
CREATE TABLE Flight (
  flight_id           INT IDENTITY(1,1) PRIMARY KEY,
  flight_no           VARCHAR(10) NOT NULL,
  airline_id          INT NOT NULL REFERENCES Airline(airline_id),
  aircraft_id         INT NOT NULL REFERENCES Aircraft(aircraft_id),
  origin_airport_id   INT NOT NULL REFERENCES Airport(airport_id),
  dest_airport_id     INT NOT NULL REFERENCES Airport(airport_id),
  flight_date         DATE NOT NULL,
  passengers_on_board SMALLINT NOT NULL DEFAULT 0,
  CONSTRAINT ck_flight_pax   CHECK (passengers_on_board >= 0),
  CONSTRAINT ck_flight_route CHECK (origin_airport_id <> dest_airport_id)
);

-- What: maintenance history of an aircraft, with the date the next maintenance is due.
-- Why:  one-to-many from Aircraft; next_due_date in the past drives the "maintenance overdue" warning.
-- Who:  Member A
CREATE TABLE Maintenance_Record (
  maint_id      INT IDENTITY(1,1) PRIMARY KEY,
  aircraft_id   INT NOT NULL REFERENCES Aircraft(aircraft_id),
  maint_date    DATE NOT NULL,
  maint_type    VARCHAR(20) NOT NULL,
  notes         VARCHAR(500) NULL,
  next_due_date DATE NULL,
  CONSTRAINT ck_maint_type CHECK (maint_type IN ('Routine','Inspection','Repair','Heavy')),
  CONSTRAINT ck_maint_due  CHECK (next_due_date IS NULL OR next_due_date >= maint_date)
);
GO

/* ---------- INCIDENT AND ITS CHILD TABLES ---------- */

-- What: the main table - one row per aviation incident.
-- Why:  row_ver (ROWVERSION) detects two users editing the same row; is_deleted/deleted_at = soft delete; is_archived hides old closed cases;
--       airport_id/flight_id are optional because crashes can happen away from an airport (location text stays);
--       DATETIME2 is more precise than DATETIME; UNIQUE (aircraft, date, phase) means "same event".
-- Who:  Member A
CREATE TABLE Incident (
  incident_id         INT IDENTITY(1,1) PRIMARY KEY,
  aircraft_id         INT NOT NULL REFERENCES Aircraft(aircraft_id),
  airport_id          INT NULL REFERENCES Airport(airport_id),
  flight_id           INT NULL REFERENCES Flight(flight_id),
  incident_date       DATE NOT NULL,
  location            VARCHAR(120) NOT NULL,
  phase_of_flight     VARCHAR(20)  NOT NULL,
  severity            VARCHAR(20)  NOT NULL,
  fatalities          INT NOT NULL DEFAULT 0,
  injuries            INT NOT NULL DEFAULT 0,
  passengers_on_board SMALLINT NULL,
  status              VARCHAR(20) NOT NULL DEFAULT 'Open',
  description         VARCHAR(MAX) NULL,
  recorded_by         VARCHAR(100) NULL DEFAULT SUSER_SNAME(),
  is_deleted          BIT NOT NULL DEFAULT 0,
  deleted_at          DATETIME2 NULL,
  is_archived         BIT NOT NULL DEFAULT 0,
  created_at          DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  row_ver             ROWVERSION,
  CONSTRAINT ck_incident_phase CHECK (phase_of_flight IN ('Taxi','Takeoff','Climb','Cruise','Descent','Approach','Landing')),
  CONSTRAINT ck_incident_sev   CHECK (severity IN ('Minor','Serious','Major','Fatal')),
  CONSTRAINT ck_incident_fat   CHECK (fatalities >= 0),
  CONSTRAINT ck_incident_inj   CHECK (injuries >= 0),
  CONSTRAINT ck_incident_pax   CHECK (passengers_on_board IS NULL OR passengers_on_board >= 0),
  CONSTRAINT ck_incident_stat  CHECK (status IN ('Open','Under Investigation','Closed')),
  CONSTRAINT uq_incident_event UNIQUE (aircraft_id, incident_date, phase_of_flight)
);

-- What: weather at the time of one incident (exactly one row per incident).
-- Why:  1:1 with Incident (UNIQUE foreign key); ON DELETE CASCADE because weather has no meaning without its incident.
-- Who:  Member A
CREATE TABLE Weather_Condition (
  weather_id     INT IDENTITY(1,1) PRIMARY KEY,
  incident_id    INT NOT NULL UNIQUE REFERENCES Incident(incident_id) ON DELETE CASCADE,
  condition_type VARCHAR(40) NOT NULL,
  visibility_km  DECIMAL(5,1) NULL,
  wind_speed_kmh INT NULL,
  temperature_c  INT NULL
);

-- What: link table between Incident and Cause (many-to-many), with a flag for the primary cause.
-- Why:  composite primary key stops duplicates; a filtered unique index allows only ONE primary cause per incident; CASCADE with its incident.
-- Who:  Member A
CREATE TABLE Incident_Cause (
  incident_id INT NOT NULL REFERENCES Incident(incident_id) ON DELETE CASCADE,
  cause_id    INT NOT NULL REFERENCES Cause(cause_id),
  is_primary  BIT NOT NULL DEFAULT 0,
  PRIMARY KEY (incident_id, cause_id)
);
CREATE UNIQUE INDEX uq_one_primary_cause ON Incident_Cause(incident_id) WHERE is_primary = 1;

-- What: link table between Incident and Crew_Member (many-to-many) with the person's role and injury level in that incident.
-- Why:  role and injury belong to the pair (incident, person), not to the person alone, so they live in the link table; CASCADE with its incident.
-- Who:  Member A
CREATE TABLE Incident_Crew (
  incident_id    INT NOT NULL REFERENCES Incident(incident_id) ON DELETE CASCADE,
  crew_id        INT NOT NULL REFERENCES Crew_Member(crew_id),
  role_on_flight VARCHAR(40) NOT NULL,
  injury_status  VARCHAR(10) NOT NULL DEFAULT 'None',
  PRIMARY KEY (incident_id, crew_id),
  CONSTRAINT ck_crew_injury CHECK (injury_status IN ('None','Minor','Serious','Fatal'))
);
GO

/* ---------- AUDIT LOG v2 ---------- */

-- What: history of changes (who changed which column of which row, old value and new value).
-- Why:  the old log kept only status; this one stores any column. The primary key is NONCLUSTERED on purpose, because Member B
--       adds a CLUSTERED index on changed_at (task B7) for fast date-range queries.
-- Who:  Member A
CREATE TABLE Audit_Log (
  log_id      INT IDENTITY(1,1) PRIMARY KEY NONCLUSTERED,
  table_name  VARCHAR(40) NOT NULL,
  record_id   INT NOT NULL,
  action_type VARCHAR(10) NOT NULL,
  column_name VARCHAR(60) NULL,
  old_value   VARCHAR(500) NULL,
  new_value   VARCHAR(500) NULL,
  changed_at  DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  changed_by  VARCHAR(100) NULL,
  CONSTRAINT ck_audit_action CHECK (action_type IN ('INSERT','UPDATE','DELETE'))
);

/* ---------- CSV IMPORT TABLES (task A3 uses these) ---------- */

-- What: one row per uploaded import file (who, when, how many rows, result).
-- Why:  lets the admin see the history of imports and the counts of good and bad rows.
-- Who:  Member A
CREATE TABLE Import_Batch (
  batch_id    INT IDENTITY(1,1) PRIMARY KEY,
  file_name   VARCHAR(200) NOT NULL,
  uploaded_by VARCHAR(100) NULL,
  uploaded_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  total_rows  INT NOT NULL DEFAULT 0,
  ok_rows     INT NOT NULL DEFAULT 0,
  error_rows  INT NOT NULL DEFAULT 0,
  status      VARCHAR(12) NOT NULL DEFAULT 'Uploaded',
  CONSTRAINT ck_batch_status CHECK (status IN ('Uploaded','Validated','Imported','Failed'))
);

-- What: raw CSV rows copied as-is before validation (the staging area).
-- Why:  every raw_* column is VARCHAR on purpose, because real files are dirty (bad dates, words in number columns);
--       the procedure validates with TRY_CONVERT and only then inserts into the real tables. CASCADE: delete a batch, delete its rows.
-- Who:  Member A
CREATE TABLE Import_Staging (
  stage_id         INT IDENTITY(1,1) PRIMARY KEY,
  batch_id         INT NOT NULL REFERENCES Import_Batch(batch_id) ON DELETE CASCADE,
  row_no           INT NOT NULL,
  raw_date         VARCHAR(200) NULL,
  raw_location     VARCHAR(200) NULL,
  raw_registration VARCHAR(200) NULL,
  raw_airline      VARCHAR(200) NULL,
  raw_model        VARCHAR(200) NULL,
  raw_phase        VARCHAR(200) NULL,
  raw_fatalities   VARCHAR(200) NULL,
  raw_injuries     VARCHAR(200) NULL,
  raw_weather      VARCHAR(200) NULL,
  row_status       VARCHAR(10) NOT NULL DEFAULT 'New',
  error_message    VARCHAR(300) NULL,
  CONSTRAINT ck_stage_status CHECK (row_status IN ('New','Valid','Warning','Error','Duplicate','Imported'))
);
GO

/* ================= TRIGGERS (incident side) ================= */

-- What: blocks bad incident dates (future date, before the aircraft was built, after its investigation started).
-- Why:  a CHECK constraint cannot look at another table or at today's date reliably; a trigger can. THROW gives a clear error number.
-- Who:  Member A
CREATE TRIGGER trg_incident_date ON Incident AFTER INSERT, UPDATE AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS (SELECT 1 FROM inserted WHERE incident_date > CAST(GETDATE() AS DATE))
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50001, 'Incident date cannot be in the future', 1;
  END
  IF EXISTS (SELECT 1 FROM inserted i JOIN Aircraft a ON a.aircraft_id = i.aircraft_id
             WHERE YEAR(i.incident_date) < a.year_built)
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50006, 'Incident date is before the aircraft was built', 1;
  END
  -- Investigation belongs to Member B's file. Until it exists this check is skipped, so this file runs alone.
  IF OBJECT_ID(N'dbo.Investigation', N'U') IS NOT NULL
  BEGIN
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.Investigation v ON v.incident_id = i.incident_id
               WHERE v.start_date < i.incident_date)
    BEGIN
      ROLLBACK TRANSACTION;
      THROW 50007, 'Incident date cannot be after its investigation started', 1;
    END
  END
END;
GO

-- What: writes an Audit_Log row whenever an incident's status changes (old value and new value).
-- Why:  keeps a history of who closed or reopened an incident; the user name comes from SESSION_CONTEXT set by the Flask app.
--       Updated to the Audit_Log v2 columns. (A7 will extend it to log every column.)
-- Who:  Member A
CREATE TRIGGER trg_incident_audit ON Incident AFTER UPDATE AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO Audit_Log(table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
  SELECT 'Incident', i.incident_id, 'UPDATE', 'status', d.status, i.status,
         COALESCE(CAST(SESSION_CONTEXT(N'app_user') AS VARCHAR(100)), SUSER_SNAME())
  FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id
  WHERE d.status <> i.status;
END;
GO
