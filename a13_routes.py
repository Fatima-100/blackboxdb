"""a13_routes.py - A13: Advanced search (/search), Risk score (/risk), and Demo mode (/admin/demo) (Member A).

Routes:
  GET  /search             -> calls sp_SearchIncidents, shareable GET URLs, highlights search words
  GET  /risk               -> reads v_aircraft_risk (fn_AircraftRiskBreakdown / fn_AircraftRiskScore),
                              Aircraft & Airlines tabs, top-10 chart, clickable breakdown
  GET/POST /admin/demo     -> Admin-only demo reset (type RESET) + viva checklist
  GET  /admin/demo/status  -> JSON progress for the background reset thread

Wire into app.py (just before `if __name__ == "__main__":`):
    import a13_routes
    a13_routes.register(app, PERMS)
"""
import datetime as dt
import os
import re
import subprocess
import sys
import threading

import pyodbc
from flask import flash, jsonify, redirect, render_template, request, session, url_for
from markupsafe import Markup, escape

from db import CONN_STR, clean, conn, execute, query

SEVERITIES = ("Minor", "Serious", "Major", "Fatal")
SORTS = (
    ("date_desc", "Newest first"),
    ("date_asc", "Oldest first"),
    ("severity", "Severity (highest)"),
    ("fatalities", "Fatalities (highest)"),
)
PAGE_SIZES = (10, 25, 50, 100)

_demo_lock = threading.Lock()
_demo_state = {"running": False, "percent": 0, "step": "Idle", "error": None, "done": False}


def _airline_scope():
    if session.get("role") == "Airline":
        return session.get("airline_id")
    return None


def _int_or_none(val):
    if val in (None, ""):
        return None
    try:
        return int(val)
    except (TypeError, ValueError):
        return None


def highlight_terms(text, search_text):
    """HTML-escape text, then highlight each search word with <mark>."""
    if not text:
        return ""
    safe = str(escape(text))
    words = [w for w in re.split(r"\s+", (search_text or "").strip()) if len(w) >= 2]
    if not words:
        return Markup(safe)
    pattern = re.compile("(" + "|".join(re.escape(str(escape(w))) for w in words) + ")", re.IGNORECASE)
    return Markup(pattern.sub(r"<mark>\1</mark>", safe))


# ------------------------------------------------------------------ /search
def search_page():
    args = request.args
    locked = _airline_scope()

    text = (args.get("text") or "").strip()
    airline_id = locked if locked is not None else _int_or_none(args.get("airline"))
    type_id = _int_or_none(args.get("type"))
    cause_id = _int_or_none(args.get("cause"))
    severities = [s for s in args.getlist("severity") if s in SEVERITIES]
    from_date = (args.get("from_date") or "").strip() or None
    to_date = (args.get("to_date") or "").strip() or None
    airport_id = _int_or_none(args.get("airport"))

    sort = args.get("sort", "date_desc")
    if sort not in dict(SORTS):
        sort = "date_desc"
    page_size = _int_or_none(args.get("page_size")) or 25
    if page_size not in PAGE_SIZES:
        page_size = 25
    page = max(1, _int_or_none(args.get("page")) or 1)

    sev_param = ",".join(severities) if severities else None

    rows, total = [], 0
    err = None
    c = conn()
    try:
        cur = c.cursor()
        cur.execute(
            """SET NOCOUNT ON;
               DECLARE @total INT = 0;
               EXEC dbo.sp_SearchIncidents
                   @text=?, @airline_id=?, @type_id=?, @cause_id=?,
                   @severity=?, @from_date=?, @to_date=?, @airport_id=?,
                   @user_airline_id=?, @page=?, @page_size=?, @sort=?,
                   @total=@total OUTPUT;
               SELECT @total AS total_rows;""",
            (
                text or None,
                airline_id,
                type_id,
                cause_id,
                sev_param,
                from_date,
                to_date,
                airport_id,
                locked,
                page,
                page_size,
                sort,
            ),
        )
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        cur.nextset()
        if cur.description:
            total = int(cur.fetchone()[0] or 0)
    except pyodbc.Error as e:
        err = clean(e)
        flash(f"Search error: {err}", "danger")
    finally:
        c.close()

    total_pages = max(1, (total + page_size - 1) // page_size)
    start_idx = ((page - 1) * page_size + 1) if total > 0 and rows else 0
    end_idx = ((page - 1) * page_size + len(rows)) if total > 0 and rows else 0

    airlines = (
        query("SELECT airline_id, name FROM dbo.Airline WHERE airline_id = ?", (locked,))
        if locked is not None
        else query("SELECT airline_id, name FROM dbo.Airline ORDER BY name")
    )
    types = query("SELECT type_id, manufacturer, model FROM dbo.Aircraft_Type ORDER BY manufacturer, model")
    causes = query("SELECT cause_id, cause_name FROM dbo.Cause ORDER BY cause_name")
    airports = query("SELECT airport_id, iata_code, name, city FROM dbo.Airport ORDER BY name")

    # Preserve all active filters for page links
    base_qs = []
    for k in ("text", "airline", "type", "cause", "from_date", "to_date", "airport", "sort", "page_size"):
        v = args.get(k)
        if v:
            base_qs.append((k, v))
    for s in severities:
        base_qs.append(("severity", s))

    return render_template(
        "search.html",
        rows=rows,
        total=total,
        page=page,
        page_size=page_size,
        total_pages=total_pages,
        start_idx=start_idx,
        end_idx=end_idx,
        text=text,
        airline_id=airline_id,
        type_id=type_id,
        cause_id=cause_id,
        severities=severities,
        from_date=from_date or "",
        to_date=to_date or "",
        airport_id=airport_id,
        sort=sort,
        sorts=SORTS,
        page_sizes=PAGE_SIZES,
        all_severities=SEVERITIES,
        airlines=airlines,
        types=types,
        causes=causes,
        airports=airports,
        locked_airline=locked,
        base_qs=base_qs,
    )


# ------------------------------------------------------------------ /risk
def risk_page():
    locked = _airline_scope()
    where = "WHERE airline_id = ?" if locked is not None else ""
    params = (locked,) if locked is not None else ()

    aircraft_rows = query(
        f"""SELECT aircraft_id, registration_no, airline_id, airline,
                   incident_points, fatality_points, age_points, overdue_points,
                   raw_total, risk_score, risk_percentile, risk_band, risk_rank
              FROM dbo.v_aircraft_risk
              {where}
             ORDER BY raw_total DESC, risk_score DESC, registration_no""",
        params,
    )

    airline_rows = query(
        f"""SELECT airline_id, airline,
                   COUNT(*) AS aircraft_count,
                   CAST(AVG(CAST(risk_score AS FLOAT)) AS DECIMAL(5,1)) AS avg_score,
                   CAST(AVG(CAST(raw_total AS FLOAT)) AS DECIMAL(7,1)) AS avg_raw,
                   MAX(risk_score) AS max_score,
                   MAX(raw_total) AS max_raw
              FROM dbo.v_aircraft_risk
              {where}
             GROUP BY airline_id, airline
             ORDER BY avg_raw DESC, avg_score DESC, airline""",
        params,
    )

    top10 = [
        {
            "label": f"{r['registration_no']} ({r['airline']})",
            "raw": float(r["raw_total"]),
            "score": float(r["risk_score"]),
            "band": r["risk_band"],
        }
        for r in aircraft_rows[:10]
    ]

    return render_template(
        "risk.html",
        aircraft_rows=aircraft_rows,
        airline_rows=airline_rows,
        top10=top10,
        locked_airline=locked,
    )


# ------------------------------------------------------------------ /admin/demo
VIVA_CHECKLIST = [
    ("1. Schema & Constraints", "Run demo_a.sql (bad inserts: lat 120, year 1800, same origin/dest)", "All 15 checks return PASS"),
    ("2. 10,000+ Seed Data", "SELECT COUNT(*) FROM Incident; SELECT COUNT(*) FROM Airport;", "10,000 incidents, 62 airports, fixed seed (IDs 1-150)"),
    ("3. Query Library (A9)", "Open /queries or run python test_queries_a.py", "All 23 queries PASS under 2000 ms"),
    ("4. Views & Indexed View (A5)", "Run demo_a_A5.sql with Ctrl+M (Actual Execution Plan)", "WITH (NOEXPAND) reads ix_v_incident_phase_stats"),
    ("5. Index Proof (A8)", "Open docs/index_proof_a.md & run A8_proof.sql", "Clustered Index Scan -> Index Seek, logical reads drop"),
    ("6. Triggers & Audit (A7)", "Run demo_a_A7.sql (soft delete, audit v2, crew fatal 50101, grounding)", "All trigger tests PASS"),
    ("7. Procedures & Wizard (A4/A10)", "Open /incident/new/1?new=1 or run python test_wizard.py", "10/10 wizard tests PASS; only sp_AddIncident called"),
    ("8. Charts & Map (A11/A12)", "Open / (Dashboard) and /map; toggle Fatal off, test offline", "Charts filter table; map clusters 5,989 pins"),
    ("9. Search, Risk & Similar (A13)", "Open /search?text=engine, /risk, and any /incident/1", "Highlighted search, risk bands, similar incident chips"),
]


def _run_sql_file(cur, path):
    with open(path, "r", encoding="utf-8") as fh:
        sql_text = fh.read()
    batches = re.split(r"(?im)^\s*GO\s*$", sql_text)
    for batch in batches:
        stmt = batch.strip()
        if stmt:
            cur.execute(stmt)


def _reset_worker(username):
    root = os.path.dirname(os.path.abspath(__file__))
    try:
        # Decide whether merged schema.sql exists or Member A's standalone SQL files
        if os.path.exists(os.path.join(root, "schema_people.sql")) and os.path.exists(os.path.join(root, "schema.sql")):
            sql_files = ["schema.sql"]
            seed_script = "seed.py" if os.path.exists(os.path.join(root, "seed.py")) else "seed_a.py"
        else:
            sql_files = [
                f for f in (
                    "00_create_db.sql",
                    "schema_incident.sql",
                    "objects_a_A4.sql",
                    "views_a_A5.sql",
                    "objects_a_A6.sql",
                    "objects_a_A7.sql",
                    "objects_a_A7_view.sql",
                    "objects_a_A8_indexes.sql",
                    "objects_a_A12.sql",
                    "objects_a_A13.sql",
                )
                if os.path.exists(os.path.join(root, f))
            ]
            seed_script = "seed_a.py"

        total_steps = len(sql_files) + 2
        master_conn = re.sub(r"DATABASE=[^;]+;", "DATABASE=master;", CONN_STR, flags=re.IGNORECASE)
        c = pyodbc.connect(master_conn, autocommit=True)
        try:
            cur = c.cursor()
            for idx, fname in enumerate(sql_files, start=1):
                with _demo_lock:
                    _demo_state["step"] = f"Running {fname} ({idx}/{len(sql_files)})..."
                    _demo_state["percent"] = int((idx / total_steps) * 55)
                _run_sql_file(cur, os.path.join(root, fname))
        finally:
            c.close()

        with _demo_lock:
            _demo_state["step"] = f"Seeding database with {seed_script}..."
            _demo_state["percent"] = 65
        proc = subprocess.run(
            [sys.executable, os.path.join(root, seed_script)],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=180,
        )
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or f"{seed_script} failed")

        with _demo_lock:
            _demo_state["step"] = "Logging reset to Audit_Log..."
            _demo_state["percent"] = 95
        execute(
            """INSERT INTO dbo.Audit_Log
                   (table_name, record_id, action_type, column_name, old_value, new_value, changed_by)
               VALUES ('System', 0, 'INSERT', 'demo_reset', NULL, ?, ?)""",
            (f"Demo reset completed at {dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", username),
        )
        with _demo_lock:
            _demo_state.update(running=False, percent=100, step="Demo database reset complete.", error=None, done=True)
    except Exception as exc:
        with _demo_lock:
            _demo_state.update(running=False, step="Failed", error=str(exc), done=True)


def demo_mode():
    if request.method == "POST":
        confirm = (request.form.get("confirm") or "").strip()
        if confirm != "RESET":
            flash("Type RESET in all caps to confirm the database reset.", "danger")
            return redirect(url_for("demo_mode"))
        with _demo_lock:
            if _demo_state["running"]:
                flash("A demo reset is already running.", "warning")
                return redirect(url_for("demo_mode"))
            _demo_state.update(running=True, percent=5, step="Starting reset...", error=None, done=False)
        t = threading.Thread(target=_reset_worker, args=(session.get("username", "admin"),), daemon=True)
        t.start()
        flash("Demo database reset started in background.", "info")
        return redirect(url_for("demo_mode"))

    with _demo_lock:
        state = dict(_demo_state)
    return render_template("demo_mode.html", state=state, checklist=VIVA_CHECKLIST)


def demo_status():
    with _demo_lock:
        return jsonify(dict(_demo_state))


def register(app, perms):
    ALL = ("Admin", "Investigator", "Officer", "Airline")
    perms["search_page"] = ALL
    perms["risk_page"] = ALL
    perms["demo_mode"] = ("Admin",)
    perms["demo_status"] = ("Admin",)

    app.jinja_env.filters["highlight_terms"] = highlight_terms
    app.add_url_rule("/search", "search_page", search_page)
    app.add_url_rule("/risk", "risk_page", risk_page)
    app.add_url_rule("/admin/demo", "demo_mode", demo_mode, methods=["GET", "POST"])
    app.add_url_rule("/admin/demo/status", "demo_status", demo_status)
