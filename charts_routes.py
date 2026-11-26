"""charts_routes.py - A11: JSON API endpoints and interactive dashboard (Member A).

Endpoints (all require login; Airline users get only their own data):
  GET /api/stats/yearly   -> sp_YearlyStats  -> {years, Minor, Serious, Major, Fatal}
  GET /api/stats/causes   -> top-10 causes   -> [{label, n}]
  GET /api/stats/phase    -> v_incident_phase_stats WITH (NOEXPAND) -> [{phase, n, fatalities}]
  GET /api/stats/monthly  -> incidents by month (1-12) -> [{month, n}]
  GET /api/incidents      -> sp_SearchIncidents paged  -> {rows, total, page, page_size}

Wire into app.py (just before `if __name__ == "__main__":`):
    import charts_routes
    charts_routes.register(app, PERMS)
"""
import datetime as dt

import pyodbc
from flask import jsonify, render_template, request, session

from db import clean, conn, query

# ------------------------------------------------------------------ helpers

def _airline_id():
    """Return the session airline_id when the user has the Airline role, else None."""
    if session.get("role") == "Airline":
        return session.get("airline_id")
    return None


def _run_sp_yearly(from_year, to_year, airline_id):
    """Call sp_YearlyStats and return rows as list-of-dicts.
    sp_YearlyStats does not filter by airline, so we add an airline JOIN ourselves
    when the caller has the Airline role."""
    if airline_id is not None:
        # Airline-scoped version: group directly without the procedure
        rows = query(
            """SELECT YEAR(i.incident_date) AS incident_year,
                      ISNULL(SUM(CASE severity WHEN 'Minor'   THEN 1 ELSE 0 END), 0) AS Minor,
                      ISNULL(SUM(CASE severity WHEN 'Serious' THEN 1 ELSE 0 END), 0) AS Serious,
                      ISNULL(SUM(CASE severity WHEN 'Major'   THEN 1 ELSE 0 END), 0) AS Major,
                      ISNULL(SUM(CASE severity WHEN 'Fatal'   THEN 1 ELSE 0 END), 0) AS Fatal,
                      COUNT(*) AS Total
               FROM dbo.Incident i
               JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
               WHERE i.is_deleted = 0 AND a.airline_id = ?
                 AND YEAR(i.incident_date) BETWEEN ? AND ?
               GROUP BY YEAR(i.incident_date)
               ORDER BY incident_year""",
            (airline_id, from_year, to_year),
        )
        return [dict(r) for r in rows]

    # Staff path: use the procedure
    c = conn()
    try:
        cur = c.cursor()
        cur.execute("SET NOCOUNT ON; EXEC dbo.sp_YearlyStats @from_year=?, @to_year=?",
                    (from_year, to_year))
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, row)) for row in cur.fetchall()]
        return rows
    finally:
        c.close()


def _int_arg(name, default, lo=None, hi=None):
    try:
        v = int(request.args.get(name, default))
    except (TypeError, ValueError):
        v = default
    if lo is not None and v < lo:
        v = lo
    if hi is not None and v > hi:
        v = hi
    return v


# ------------------------------------------------------------------ routes

def api_yearly():
    """GET /api/stats/yearly?from_year=1995&to_year=<current>"""
    cur_year = dt.date.today().year
    from_year = _int_arg("from_year", 1995, lo=1900, hi=cur_year)
    to_year   = _int_arg("to_year",   cur_year, lo=from_year, hi=cur_year)
    airline   = _airline_id()
    try:
        rows = _run_sp_yearly(from_year, to_year, airline)
    except pyodbc.Error as e:
        return jsonify(error=clean(e)), 500
    out = {
        "years":   [r["incident_year"] for r in rows],
        "Minor":   [r["Minor"]   for r in rows],
        "Serious": [r["Serious"] for r in rows],
        "Major":   [r["Major"]   for r in rows],
        "Fatal":   [r["Fatal"]   for r in rows],
        "Total":   [r["Total"]   for r in rows],
    }
    return jsonify(out)


def api_causes():
    """GET /api/stats/causes?top=10"""
    top     = _int_arg("top", 10, lo=1, hi=50)
    airline = _airline_id()
    if airline is not None:
        sql = """SELECT TOP (?) c.cause_name AS label, COUNT(*) AS n
                 FROM dbo.Incident_Cause ic
                 JOIN dbo.Cause c ON c.cause_id = ic.cause_id
                 JOIN dbo.Incident i ON i.incident_id = ic.incident_id
                 JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
                 WHERE i.is_deleted = 0 AND a.airline_id = ?
                 GROUP BY c.cause_name ORDER BY n DESC"""
        rows = query(sql, (top, airline))
    else:
        sql = """SELECT TOP (?) c.cause_name AS label, COUNT(*) AS n
                 FROM dbo.Incident_Cause ic
                 JOIN dbo.Cause c ON c.cause_id = ic.cause_id
                 JOIN dbo.Incident i ON i.incident_id = ic.incident_id
                 WHERE i.is_deleted = 0
                 GROUP BY c.cause_name ORDER BY n DESC"""
        rows = query(sql, (top,))
    return jsonify([{"label": r["label"], "n": r["n"]} for r in rows])


def api_phase():
    """GET /api/stats/phase  — reads the indexed view (WITH NOEXPAND for Express)."""
    airline = _airline_id()
    if airline is not None:
        # Indexed view has no airline column; fall back to the base table
        sql = """SELECT i.phase_of_flight AS phase, COUNT(*) AS n,
                        ISNULL(SUM(i.fatalities), 0) AS fatalities
                 FROM dbo.Incident i
                 JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id
                 WHERE i.is_deleted = 0 AND a.airline_id = ?
                 GROUP BY i.phase_of_flight"""
        rows = query(sql, (airline,))
    else:
        sql = """SELECT phase_of_flight AS phase, n, fatalities
                 FROM dbo.v_incident_phase_stats WITH (NOEXPAND)"""
        rows = query(sql)
    return jsonify([{"phase": r["phase"], "n": r["n"], "fatalities": r["fatalities"]}
                    for r in rows])


def api_monthly():
    """GET /api/stats/monthly?from_year=&to_year=&severity=  — seasonality by month."""
    cur_year  = dt.date.today().year
    from_year = _int_arg("from_year", 1995, lo=1900, hi=cur_year)
    to_year   = _int_arg("to_year",   cur_year, lo=from_year, hi=cur_year)
    severity  = request.args.get("severity", "")
    airline   = _airline_id()

    where = "WHERE i.is_deleted = 0 AND YEAR(i.incident_date) BETWEEN ? AND ?"
    params = [from_year, to_year]
    if severity:
        where += " AND i.severity = ?"
        params.append(severity)
    if airline is not None:
        where += " AND a.airline_id = ?"
        params.append(airline)
        join = "JOIN dbo.Aircraft a ON a.aircraft_id = i.aircraft_id"
    else:
        join = ""

    sql = f"""SELECT MONTH(i.incident_date) AS month, COUNT(*) AS n
              FROM dbo.Incident i {join}
              {where}
              GROUP BY MONTH(i.incident_date)
              ORDER BY month"""
    rows = query(sql, params)
    # fill all 12 months (some may have zero)
    by_month = {r["month"]: r["n"] for r in rows}
    return jsonify([{"month": m, "n": by_month.get(m, 0)} for m in range(1, 13)])


def api_incidents():
    """GET /api/incidents — calls sp_SearchIncidents; returns paged rows + total."""
    args   = request.args
    page   = _int_arg("page", 1, lo=1)
    size   = _int_arg("page_size", 25, lo=5, hi=200)
    sort   = args.get("sort", "date_desc")
    if sort not in ("date_desc", "date_asc", "severity", "fatalities"):
        sort = "date_desc"

    # collect optional filters
    text       = args.get("text") or None
    airline_id = _int_arg("airline_id", None) if args.get("airline_id") else None
    type_id    = _int_arg("type_id",    None) if args.get("type_id")    else None
    cause_id   = _int_arg("cause_id",   None) if args.get("cause_id")   else None
    severity   = args.get("severity") or None
    from_date  = args.get("from_date") or None
    to_date    = args.get("to_date")   or None
    airport_id = _int_arg("airport_id", None) if args.get("airport_id") else None

    # Airline users always see only their own data
    user_airline = _airline_id()

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
            (text, airline_id, type_id, cause_id,
             severity, from_date, to_date, airport_id,
             user_airline, page, size, sort),
        )
        # first result set = incident rows
        cols  = [d[0] for d in cur.description]
        rows  = [dict(zip(cols, row)) for row in cur.fetchall()]
        # second result set = total
        cur.nextset()
        total = cur.fetchone()[0] if cur.description else 0
        # make dates JSON-serialisable
        for r in rows:
            for k, v in r.items():
                if hasattr(v, "isoformat"):
                    r[k] = v.isoformat()
        return jsonify({"rows": rows, "total": total, "page": page, "page_size": size})
    except pyodbc.Error as e:
        return jsonify(error=clean(e)), 500
    finally:
        c.close()


def dashboard_a11():
    """GET /dashboard  — interactive chart page (replaces the old static dashboard)."""
    # KPI strip (same 3 numbers as before, one query)
    kpi = query(
        """SELECT (SELECT COUNT(*) FROM Incident WHERE is_deleted=0) AS incidents,
                  (SELECT COUNT(*) FROM v_overdue_recommendations)   AS overdue,
                  (SELECT COALESCE(SUM(fatalities),0) FROM Incident WHERE is_deleted=0) AS fatalities""",
        one=True,
    )
    # dropdowns for the filter bar
    airlines  = query("SELECT airline_id, name FROM dbo.Airline ORDER BY name")
    types     = query("SELECT type_id, model FROM dbo.Aircraft_Type ORDER BY model")
    causes    = query("SELECT cause_id, cause_name AS name FROM dbo.Cause ORDER BY cause_name")
    cur_year  = dt.date.today().year
    years     = list(range(cur_year, 1994, -1))
    # Airline users: lock the airline filter
    locked_airline = _airline_id()
    return render_template(
        "dashboard.html",
        kpi=kpi,
        airlines=airlines, types=types, causes=causes,
        years=years, cur_year=cur_year,
        locked_airline=locked_airline,
    )


# ------------------------------------------------------------------ register

def register(app, perms):
    ALL = ("Admin", "Investigator", "Officer", "Airline")
    for ep in ("api_yearly", "api_causes", "api_phase", "api_monthly",
               "api_incidents", "dashboard", "dashboard_a11"):
        perms[ep] = ALL

    app.add_url_rule("/api/stats/yearly",   "api_yearly",   api_yearly)
    app.add_url_rule("/api/stats/causes",   "api_causes",   api_causes)
    app.add_url_rule("/api/stats/phase",    "api_phase",    api_phase)
    app.add_url_rule("/api/stats/monthly",  "api_monthly",  api_monthly)
    app.add_url_rule("/api/incidents",      "api_incidents", api_incidents)
    app.add_url_rule("/",          "dashboard",    dashboard_a11)
    app.add_url_rule("/dashboard", "dashboard_a11", dashboard_a11)
