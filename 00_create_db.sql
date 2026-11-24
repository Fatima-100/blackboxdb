/* 00_create_db.sql - drops and recreates the blackboxdb database (empty).
   Run this first, then schema_incident.sql. Author: Member A */
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
