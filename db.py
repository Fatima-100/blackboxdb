import re, pyodbc
from flask import has_request_context, session

# >>> EDIT THIS: use the server name shown in the SSMS "Connect to Server" dialog <<<
SERVER = "DESKTOP-CA4FEDA\SQLEXPRESS"
DRIVER = "ODBC Driver 18 for SQL Server"     # use "ODBC Driver 17 for SQL Server" if that is what you installed

CONN_STR = (f"DRIVER={{{DRIVER}}};SERVER={SERVER};DATABASE=blackboxdb;"
            "Trusted_Connection=yes;TrustServerCertificate=yes")
# SQL login instead? Replace the line above with:
# CONN_STR = f"DRIVER={{{DRIVER}}};SERVER={SERVER};DATABASE=blackboxdb;UID=sa;PWD=yourpassword;TrustServerCertificate=yes"

def conn():
    c = pyodbc.connect(CONN_STR)
    # Tell SQL Server who is logged in, so the audit triggers can record the user name.
    if has_request_context() and session.get("username"):
        cur = c.cursor()
        cur.execute("EXEC sp_set_session_context @key = N'app_user', @value = ?", session["username"])
        cur.close()
    return c

def clean(e):
    """Pull the readable message out of a pyodbc/SQL Server error."""
    m = re.search(r"\[SQL Server\](.*?) \(\d+\)", str(e))
    return m.group(1) if m else str(e)

def query(sql, args=(), one=False):
    c = conn(); cur = c.cursor()
    try:
        cur.execute(sql, args)
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    finally:
        cur.close(); c.close()
    return (rows[0] if rows else None) if one else rows

def execute(sql, args=()):
    c = conn(); cur = c.cursor()
    try:
        cur.execute(sql, args); c.commit()
    finally:
        cur.close(); c.close()
