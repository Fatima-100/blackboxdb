/* BlackBoxDB - SQL Server (T-SQL). Open in SSMS and press F5 to run the whole file. */
USE master;
GO
IF DB_ID('blackboxdb') IS NOT NULL
BEGIN
  ALTER DATABASE blackboxdb SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
  DROP DATABASE blackboxdb;
END
GO
CREATE DATABASE blackboxdb;
GO
USE blackboxdb;
GO

CREATE TABLE Airline (
  airline_id INT IDENTITY(1,1) PRIMARY KEY,
  name VARCHAR(100) NOT NULL UNIQUE,
  country VARCHAR(60) NOT NULL,
  iata_code CHAR(2) UNIQUE
);
CREATE TABLE Aircraft_Type (
  type_id INT IDENTITY(1,1) PRIMARY KEY,
  manufacturer VARCHAR(60) NOT NULL,
  model VARCHAR(60) NOT NULL,
  category VARCHAR(30) NOT NULL,
  CONSTRAINT uq_type UNIQUE (manufacturer, model)
);
CREATE TABLE Cause (
  cause_id INT IDENTITY(1,1) PRIMARY KEY,
  cause_name VARCHAR(100) NOT NULL UNIQUE,
  category VARCHAR(40) NOT NULL
);
CREATE TABLE Investigator (
  investigator_id INT IDENTITY(1,1) PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  agency VARCHAR(80) NOT NULL,
  specialization VARCHAR(80)
);
CREATE TABLE Crew_Member (
  crew_id INT IDENTITY(1,1) PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  role VARCHAR(40) NOT NULL,
  license_no VARCHAR(30) NOT NULL UNIQUE,
  experience_years INT NOT NULL DEFAULT 0 CHECK (experience_years >= 0)
);
CREATE TABLE Aircraft (
  aircraft_id INT IDENTITY(1,1) PRIMARY KEY,
  registration_no VARCHAR(12) NOT NULL UNIQUE,
  airline_id INT NOT NULL REFERENCES Airline(airline_id),
  type_id INT NOT NULL REFERENCES Aircraft_Type(type_id),
  year_built SMALLINT
);
CREATE TABLE Incident (
  incident_id INT IDENTITY(1,1) PRIMARY KEY,
  aircraft_id INT NOT NULL REFERENCES Aircraft(aircraft_id),
  incident_date DATE NOT NULL,
  location VARCHAR(120) NOT NULL,
  phase_of_flight VARCHAR(20) NOT NULL
    CHECK (phase_of_flight IN ('Taxi','Takeoff','Climb','Cruise','Descent','Approach','Landing')),
  severity VARCHAR(20) NOT NULL CHECK (severity IN ('Minor','Serious','Major','Fatal')),
  fatalities INT NOT NULL DEFAULT 0 CHECK (fatalities >= 0),
  injuries INT NOT NULL DEFAULT 0 CHECK (injuries >= 0),
  status VARCHAR(20) NOT NULL DEFAULT 'Open' CHECK (status IN ('Open','Under Investigation','Closed')),
  description VARCHAR(MAX),
  recorded_by VARCHAR(100) NULL DEFAULT SUSER_SNAME(),
  CONSTRAINT uq_incident_event UNIQUE (aircraft_id, incident_date, phase_of_flight)   -- same aircraft, day and phase = same event
);
CREATE TABLE Weather_Condition (
  weather_id INT IDENTITY(1,1) PRIMARY KEY,
  incident_id INT NOT NULL UNIQUE REFERENCES Incident(incident_id) ON DELETE CASCADE,
  condition_type VARCHAR(40) NOT NULL,
  visibility_km DECIMAL(5,1),
  wind_speed_kmh INT,
  temperature_c INT
);
CREATE TABLE Investigation (
  investigation_id INT IDENTITY(1,1) PRIMARY KEY,
  incident_id INT NOT NULL UNIQUE REFERENCES Incident(incident_id) ON DELETE CASCADE,
  lead_investigator_id INT NOT NULL REFERENCES Investigator(investigator_id),
  start_date DATE NOT NULL,
  end_date DATE NULL,
  probable_cause_summary VARCHAR(MAX),
  CHECK (end_date IS NULL OR end_date >= start_date)
);
CREATE TABLE Safety_Recommendation (
  rec_id INT IDENTITY(1,1) PRIMARY KEY,
  incident_id INT NOT NULL REFERENCES Incident(incident_id) ON DELETE CASCADE,
  airline_id INT NOT NULL REFERENCES Airline(airline_id),
  rec_text VARCHAR(MAX) NOT NULL,
  issued_date DATE NOT NULL,
  due_date DATE NOT NULL,
  status VARCHAR(10) NOT NULL DEFAULT 'Open' CHECK (status IN ('Open','Closed')),
  response_text VARCHAR(MAX),
  closed_date DATE NULL,
  CHECK (due_date >= issued_date)
);
CREATE TABLE Incident_Cause (
  incident_id INT NOT NULL REFERENCES Incident(incident_id) ON DELETE CASCADE,
  cause_id INT NOT NULL REFERENCES Cause(cause_id),
  is_primary BIT NOT NULL DEFAULT 0,
  PRIMARY KEY (incident_id, cause_id)
);
CREATE TABLE Incident_Crew (
  incident_id INT NOT NULL REFERENCES Incident(incident_id) ON DELETE CASCADE,
  crew_id INT NOT NULL REFERENCES Crew_Member(crew_id),
  role_on_flight VARCHAR(40) NOT NULL,
  injury_status VARCHAR(10) NOT NULL DEFAULT 'None' CHECK (injury_status IN ('None','Minor','Serious','Fatal')),
  PRIMARY KEY (incident_id, crew_id)
);
CREATE UNIQUE INDEX uq_one_primary_cause ON Incident_Cause(incident_id) WHERE is_primary = 1;

CREATE TABLE Audit_Log (
  log_id INT IDENTITY(1,1) PRIMARY KEY,
  table_name VARCHAR(40) NOT NULL,
  record_id INT NOT NULL,
  old_status VARCHAR(30),
  new_status VARCHAR(30),
  changed_at DATETIME NOT NULL DEFAULT GETDATE(),
  changed_by VARCHAR(100)
);

CREATE TABLE Users (
  user_id INT IDENTITY(1,1) PRIMARY KEY,
  username VARCHAR(50) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  role VARCHAR(20) NOT NULL CHECK (role IN ('Admin','Investigator','Officer','Airline')),
  airline_id INT NULL REFERENCES Airline(airline_id),
  CHECK ((role = 'Airline' AND airline_id IS NOT NULL) OR (role <> 'Airline' AND airline_id IS NULL))
);
GO

/* ================= TRIGGERS ================= */
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
  IF EXISTS (SELECT 1 FROM inserted i JOIN Investigation v ON v.incident_id = i.incident_id
             WHERE v.start_date < i.incident_date)
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50007, 'Incident date cannot be after its investigation started', 1;
  END
END;
GO

CREATE TRIGGER trg_incident_audit ON Incident AFTER UPDATE AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO Audit_Log(table_name, record_id, old_status, new_status, changed_by)
  SELECT 'Incident', i.incident_id, d.status, i.status, COALESCE(CAST(SESSION_CONTEXT(N'app_user') AS VARCHAR(100)), SUSER_SNAME())
  FROM inserted i JOIN deleted d ON d.incident_id = i.incident_id
  WHERE d.status <> i.status;
END;
GO

CREATE TRIGGER trg_investigation_open ON Investigation AFTER INSERT AS
BEGIN
  SET NOCOUNT ON;
  UPDATE inc
     SET status = CASE WHEN i.end_date IS NULL THEN 'Under Investigation' ELSE 'Closed' END
  FROM Incident inc JOIN inserted i ON i.incident_id = inc.incident_id;
END;
GO

CREATE TRIGGER trg_investigation_close ON Investigation AFTER UPDATE AS
BEGIN
  SET NOCOUNT ON;
  UPDATE inc
     SET status = CASE WHEN i.end_date IS NOT NULL THEN 'Closed' ELSE 'Under Investigation' END
  FROM Incident inc
  JOIN inserted i ON i.incident_id = inc.incident_id
  JOIN deleted d ON d.investigation_id = i.investigation_id
  WHERE (i.end_date IS NOT NULL AND d.end_date IS NULL)
     OR (i.end_date IS NULL AND d.end_date IS NOT NULL);
END;
GO

CREATE TRIGGER trg_investigation_dates ON Investigation AFTER INSERT, UPDATE AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS (SELECT 1 FROM inserted WHERE start_date > CAST(GETDATE() AS DATE))
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50003, 'Investigation start date cannot be in the future', 1;
  END
  IF EXISTS (SELECT 1 FROM inserted WHERE end_date > CAST(GETDATE() AS DATE))
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50004, 'Investigation end date cannot be in the future', 1;
  END
  IF EXISTS (SELECT 1 FROM inserted i JOIN Incident n ON n.incident_id = i.incident_id
             WHERE i.start_date < n.incident_date)
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50005, 'Investigation cannot start before the incident date', 1;
  END
END;
GO
EXEC sp_settriggerorder @triggername = 'trg_investigation_dates', @order = 'First', @stmttype = 'INSERT';
EXEC sp_settriggerorder @triggername = 'trg_investigation_dates', @order = 'First', @stmttype = 'UPDATE';
GO

CREATE TRIGGER trg_rec_close ON Safety_Recommendation AFTER INSERT, UPDATE AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS (SELECT 1 FROM inserted
             WHERE status = 'Closed' AND (response_text IS NULL OR LTRIM(RTRIM(response_text)) = ''))
  BEGIN
    ROLLBACK TRANSACTION;
    THROW 50002, 'Cannot close a recommendation without a response text', 1;
  END
  UPDATE r SET closed_date = CASE WHEN i.status = 'Closed' THEN COALESCE(r.closed_date, CAST(GETDATE() AS DATE)) ELSE NULL END
  FROM Safety_Recommendation r JOIN inserted i ON i.rec_id = r.rec_id
  WHERE (i.status = 'Closed' AND r.closed_date IS NULL) OR (i.status = 'Open' AND r.closed_date IS NOT NULL);
END;
GO

CREATE TRIGGER trg_rec_audit ON Safety_Recommendation AFTER UPDATE AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO Audit_Log(table_name, record_id, old_status, new_status, changed_by)
  SELECT 'Safety_Recommendation', i.rec_id, d.status, i.status, COALESCE(CAST(SESSION_CONTEXT(N'app_user') AS VARCHAR(100)), SUSER_SNAME())
  FROM inserted i JOIN deleted d ON d.rec_id = i.rec_id
  WHERE d.status <> i.status;
END;
GO

/* ================= VIEWS ================= */
CREATE VIEW v_incidents_by_year AS
SELECT YEAR(i.incident_date) AS yr, i.severity, t.model AS aircraft_type,
       COUNT(*) AS incident_count, SUM(i.fatalities) AS fatalities
FROM Incident i
JOIN Aircraft a ON a.aircraft_id = i.aircraft_id
JOIN Aircraft_Type t ON t.type_id = a.type_id
GROUP BY YEAR(i.incident_date), i.severity, t.model;
GO

CREATE VIEW v_overdue_recommendations AS
SELECT r.rec_id, r.incident_id, al.name AS airline, r.rec_text,
       r.issued_date, r.due_date, DATEDIFF(day, r.due_date, CAST(GETDATE() AS DATE)) AS days_overdue
FROM Safety_Recommendation r
JOIN Airline al ON al.airline_id = r.airline_id
WHERE r.status = 'Open' AND r.due_date < CAST(GETDATE() AS DATE);
GO

CREATE VIEW v_airline_safety_summary AS
SELECT al.airline_id, al.name AS airline,
       COALESCE(x.incidents, 0) AS incidents,
       COALESCE(x.fatalities, 0) AS fatalities,
       COALESCE(y.unresolved, 0) AS unresolved_recs
FROM Airline al
LEFT JOIN (SELECT a.airline_id, COUNT(*) AS incidents, SUM(i.fatalities) AS fatalities
           FROM Incident i JOIN Aircraft a ON a.aircraft_id = i.aircraft_id
           GROUP BY a.airline_id) x ON x.airline_id = al.airline_id
LEFT JOIN (SELECT airline_id, COUNT(*) AS unresolved
           FROM Safety_Recommendation WHERE status = 'Open'
           GROUP BY airline_id) y ON y.airline_id = al.airline_id;
GO
