"""import_routes.py - the /import pages (task A3, Member A).

Add these two lines to app.py (after PERMS is defined, before `if __name__ == "__main__":`):
    import import_routes
    import_routes.register(app, PERMS)

Flow: upload CSV -> rows go to Import_Staging and are validated (preview page) -> "Import valid rows" calls
sp_ImportIncidents -> result page -> optional download of the error rows. Admin and Officer only.
The app never trusts the file: every problem becomes a red message, never a crash.
"""
import csv, io, os, re
import pyodbc
from flask import render_template, request, redirect, url_for, flash, session, Response
from db import query, execute, conn, clean

MAX_BYTES = 5 * 1024 * 1024          # 5 MB
MAX_ROWS = 20000
CHUNK = 1000
FIELD_MAX = 200                      # Import_Staging raw columns are VARCHAR(200)
COLS = ["date", "location", "registration", "operator", "model", "phase", "fatalities", "injuries", "weather"]
RAW = ["raw_date", "raw_location", "raw_registration", "raw_airline", "raw_model", "raw_phase",
       "raw_fatalities", "raw_injuries", "raw_weather"]                     # same order as COLS
REQUIRED = ("date", "location", "registration")
ROLES = ("Admin", "Officer")


def clip(v):
    return (v or "").replace("\x00", "").strip()[:FIELD_MAX]


def read_csv(storage):
    """Return (file_name, rows, error). rows = list of 9-value lists in COLS order."""
    name = re.sub(r"[\x00-\x1f]", "", os.path.basename(storage.filename or ""))[:200]
    if not name.lower().endswith(".csv"):
        return name, None, "Only .csv files are accepted"
    data = storage.stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        return name, None, "The file is larger than 5 MB"
    if not data.strip():
        return name, None, "The file is empty"
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return name, None, "The file is not UTF-8 text (in Excel use Save As > CSV UTF-8)"
    text = text.replace("\x00", "")
    first = text.split("\n", 1)[0]
    delim = ";" if first.count(";") > first.count(",") else ","
    try:
        reader = csv.DictReader(io.StringIO(text, newline=""), delimiter=delim)
        head = {(h or "").strip().lower(): h for h in (reader.fieldnames or [])}
        missing = [c for c in REQUIRED if c not in head]
        if missing:
            return name, None, "Missing column(s): " + ", ".join(missing) + ". The first line must be the header: " + ",".join(COLS)
        rows = []
        for rec in reader:
            vals = [clip(rec.get(head[c])) if c in head else "" for c in COLS]
            if not any(vals):
                continue                                              # skip empty lines
            rows.append(vals)
            if len(rows) > MAX_ROWS:
                return name, None, f"The file has more than {MAX_ROWS:,} rows"
    except csv.Error as e:
        return name, None, f"The file could not be read as CSV ({e})"
    if not rows:
        return name, None, "The file has a header but no data rows"
    return name, rows, None


def stage(name, rows):
    """Create the batch, store the raw rows, validate - all in one transaction. Returns the batch id."""
    c = conn(); cur = c.cursor()
    try:
        cur.execute("SET NOCOUNT ON; INSERT INTO Import_Batch(file_name,uploaded_by,total_rows) VALUES(?,?,?); SELECT SCOPE_IDENTITY();",
                    name, session.get("username"), len(rows))
        bid = int(cur.fetchone()[0])
        try:
            cur.fast_executemany = True
        except AttributeError:
            pass
        sql = f"INSERT INTO Import_Staging(batch_id,row_no,{','.join(RAW)}) VALUES({','.join('?' * 11)})"
        data = [(bid, i + 1, *r) for i, r in enumerate(rows)]
        for i in range(0, len(data), CHUNK):
            cur.executemany(sql, data[i:i + CHUNK])
        cur.execute("EXEC dbo.sp_ValidateImport ?", bid)
        c.commit()
        return bid
    except Exception:
        c.rollback()
        raise
    finally:
        cur.close(); c.close()


def get_batch(bid):
    return query("SELECT * FROM Import_Batch WHERE batch_id=?", (bid,), one=True)


def safe_cell(v):
    """Stop spreadsheet formula injection in the downloaded CSV (a cell starting with = or @ would run as a formula)."""
    v = "" if v is None else str(v)
    if v and (v[0] in "=@\t\r" or (v[0] in "+-" and not re.fullmatch(r"[+-]?\d+(\.\d+)?", v))):
        return "'" + v
    return v


# ----------------------------------------------------------------------------- pages
def import_page():
    if request.method == "POST":
        f = request.files.get("file")
        if not f or not f.filename:
            flash("Choose a CSV file first", "danger")
            return redirect(url_for("import_page"))
        name, rows, err = read_csv(f)
        if err:
            flash(err, "danger")
            return redirect(url_for("import_page"))
        try:
            bid = stage(name, rows)
        except pyodbc.Error as e:
            flash(f"The database could not store this file: {clean(e)}", "danger")
            return redirect(url_for("import_page"))
        return redirect(url_for("import_preview", bid=bid))
    history = query("""SELECT TOP 10 batch_id, file_name, uploaded_by, uploaded_at, total_rows, ok_rows, error_rows, status
                       FROM Import_Batch ORDER BY batch_id DESC""")
    return render_template("import.html", history=history, cols=COLS, max_rows=MAX_ROWS)


def import_preview(bid):
    b = get_batch(bid)
    if not b:
        flash("Import batch not found", "danger")
        return redirect(url_for("import_page"))
    if b["status"] == "Imported":
        return redirect(url_for("import_result", bid=bid))
    counts = {r["row_status"]: r["n"] for r in query(
        "SELECT row_status, COUNT(*) AS n FROM Import_Staging WHERE batch_id=? GROUP BY row_status", (bid,))}
    preview = query("SELECT TOP 20 * FROM Import_Staging WHERE batch_id=? ORDER BY row_no", (bid,))
    issues = query("""SELECT TOP 200 row_no, row_status, error_message FROM Import_Staging
                      WHERE batch_id=? AND row_status IN ('Error','Warning','Duplicate')
                      ORDER BY CASE row_status WHEN 'Error' THEN 0 WHEN 'Warning' THEN 1 ELSE 2 END, row_no""", (bid,))
    importable = counts.get("Valid", 0) + counts.get("Warning", 0)
    return render_template("import_preview.html", b=b, counts=counts, preview=preview, issues=issues, importable=importable)


def import_run(bid):
    b = get_batch(bid)
    if not b:
        flash("Import batch not found", "danger")
        return redirect(url_for("import_page"))
    if b["status"] == "Imported":
        flash("This file was already imported", "warning")
        return redirect(url_for("import_result", bid=bid))
    c = None
    try:
        c = conn(); c.autocommit = True                 # the procedure runs its own transaction
        cur = c.cursor()
        cur.execute("SET NOCOUNT ON; DECLARE @i INT, @s INT, @e INT; "
                    "EXEC dbo.sp_ImportIncidents ?, @i OUTPUT, @s OUTPUT, @e OUTPUT; SELECT @i, @s, @e;", bid)
        cur.fetchone()
        cur.close()
    except pyodbc.Error as e:
        try:
            execute("UPDATE Import_Batch SET status='Failed' WHERE batch_id=? AND status<>'Imported'", (bid,))
        except pyodbc.Error:
            pass
        flash(f"The import failed and nothing was saved: {clean(e)}", "danger")
        return redirect(url_for("import_preview", bid=bid))
    finally:
        if c is not None:
            c.close()
    flash("Import finished", "success")
    return redirect(url_for("import_result", bid=bid))


def import_result(bid):
    b = get_batch(bid)
    if not b:
        flash("Import batch not found", "danger")
        return redirect(url_for("import_page"))
    if b["status"] != "Imported":
        return redirect(url_for("import_preview", bid=bid))
    dup = query("SELECT COUNT(*) AS n FROM Import_Staging WHERE batch_id=? AND row_status='Duplicate'", (bid,), one=True)["n"]
    return render_template("import_result.html", b=b, imported=b["ok_rows"], skipped=dup, errors=b["error_rows"])


def import_errors(bid):
    """CSV of the rows that failed, in the same format as the upload plus 'row' and 'error' columns, so it can be fixed and uploaded again."""
    rows = query(f"SELECT row_no, {','.join(RAW)}, error_message FROM Import_Staging "
                 "WHERE batch_id=? AND row_status='Error' ORDER BY row_no", (bid,))
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(COLS + ["row", "error"])
    for r in rows:
        w.writerow([safe_cell(r[k]) for k in RAW] + [r["row_no"], safe_cell(r["error_message"])])
    return Response("﻿" + out.getvalue(), mimetype="text/csv",
                    headers={"Content-Disposition": f'attachment; filename="import_{int(bid)}_errors.csv"'})


def register(app, perms):
    """Add the routes and allow only Admin and Officer (app.py's guard() reads PERMS)."""
    for ep in ("import_page", "import_preview", "import_run", "import_result", "import_errors"):
        perms[ep] = ROLES
    app.add_url_rule("/import", "import_page", import_page, methods=["GET", "POST"])
    app.add_url_rule("/import/<int:bid>", "import_preview", import_preview)
    app.add_url_rule("/import/<int:bid>/run", "import_run", import_run, methods=["POST"])
    app.add_url_rule("/import/<int:bid>/result", "import_result", import_result)
    app.add_url_rule("/import/<int:bid>/errors.csv", "import_errors", import_errors)
