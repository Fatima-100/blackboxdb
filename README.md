# BlackBoxDB (SQL Server + Flask)

1. Install "ODBC Driver 18 for SQL Server", then:  pip install -r requirements.txt
2. Edit SERVER in db.py to match the server name in the SSMS connect dialog.
3. SSMS: File > Open > schema.sql, then Execute (creates the database, 14 tables, triggers and views).
4. python seed.py      (simulated data; run once, re-run schema.sql first to reset)
5. python app.py       then open http://127.0.0.1:5000

## Login accounts (created by seed.py)
admin / Admin123!            Admin
investigator1 / Invest123!   Investigator
officer1 / Officer123!       Safety officer
skyline_air / Airline123!    Airline (one account per airline, e.g. meridian_airways, nordic_wings)

demo.sql = backup demo for SSMS (highlight one block at a time and Execute).
All data is simulated.
