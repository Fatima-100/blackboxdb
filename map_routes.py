"""map_routes.py - A12: Interactive incident map view and /api/map endpoint (Member A).

Routes (all logged-in roles; Airline users see only their own airline's incidents):
  GET /map      -> Leaflet map page with marker clustering, heatmap toggle & offline fallback
  GET /api/map  -> calls dbo.sp_GetMapPoints -> {points: [...], count: N}

Wire into app.py (just before `if __name__ == "__main__":`):
    import map_routes
    map_routes.register(app, PERMS)
"""
import datetime as dt

import pyodbc
from flask import jsonify, render_template, request, session

from db import clean, conn, query

VALID_SEVERITIES = ("Minor", "Serious", "Major", "Fatal")


def _locked_airline_id():
    if session.get("role") == "Airline":
        return session.get("airline_id")
    return None


def _int_arg(name, default, lo=None, hi=None):
    val = request.args.get(name)
    if val in (None, ""):
        return default
    try:
        v = int(val)
    except (TypeError, ValueError):
        return default
    if lo is not None and v < lo:
        v = lo
    if hi is not None and v > hi:
        v = hi
    return v


def map_view():
    """GET /map — renders the Leaflet incident map page."""
    cur_year = dt.date.today().year
    locked = _locked_airline_id()
    if locked is not None:
        airlines = query("SELECT airline_id, name FROM dbo.Airline WHERE airline_id = ?", (locked,))
    else:
        airlines = query("SELECT airline_id, name FROM dbo.Airline ORDER BY name")
    return render_template(
        "map.html",
        airlines=airlines,
        cur_year=cur_year,
        locked_airline=locked,
    )


def api_map():
    """GET /api/map?from_year=1995&to_year=2026&severities=Minor,Serious,Major,Fatal&airline_id="""
    cur_year = dt.date.today().year
    from_year = _int_arg("from_year", 1995, lo=1900, hi=cur_year)
    to_year = _int_arg("to_year", cur_year, lo=from_year, hi=cur_year)

    raw_sev = request.args.get("severities", "Minor,Serious,Major,Fatal")
    chosen = [s.strip() for s in raw_sev.split(",") if s.strip() in VALID_SEVERITIES]
    severity_list = ",".join(chosen)

    locked = _locked_airline_id()
    airline_id = locked if locked is not None else _int_arg("airline_id", None)

    c = conn()
    try:
        cur = c.cursor()
        cur.execute(
            "SET NOCOUNT ON; EXEC dbo.sp_GetMapPoints @from_year=?, @to_year=?, @severity_list=?, @airline_id=?;",
            (from_year, to_year, severity_list, airline_id),
        )
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        for r in rows:
            if hasattr(r.get("incident_date"), "isoformat"):
                r["incident_date"] = r["incident_date"].isoformat()
        return jsonify({"points": rows, "count": len(rows)})
    except pyodbc.Error as e:
        return jsonify(error=clean(e)), 500
    finally:
        c.close()


def register(app, perms):
    ALL = ("Admin", "Investigator", "Officer", "Airline")
    perms["map_view"] = ALL
    perms["api_map"] = ALL
    app.add_url_rule("/map", "map_view", map_view)
    app.add_url_rule("/api/map", "api_map", api_map)
