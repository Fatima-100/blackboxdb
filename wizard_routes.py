"""wizard_routes.py - A10: 5-step incident report wizard (Member A).

Nothing is saved to the database until Submit on step 5, and then ONLY
sp_AddIncident is called (one transaction inside the procedure).

Answers live in the Flask session['wizard'] as small dictionaries of raw
form values ("drafts"):  {"d1": {...}, "d2": {...}, ..., "ok": [1, 2]}
  d<n>  what the user typed on step n (kept even when it has errors, so a
        refresh or the Back button never loses it)
  ok    the steps whose draft passed the server checks
On Submit every draft is validated AGAIN, so a stale or edited answer can never
reach the database.

Wire it into app.py (just before  if __name__ == "__main__":):
    import wizard_routes
    wizard_routes.register(app, PERMS)
"""
import datetime as dt
import re

import pyodbc
from flask import (abort, flash, jsonify, redirect, render_template, request,
                   session, url_for)

from db import clean, conn, query

EDITORS = ("Admin", "Investigator")          # same roles as the old new-incident form
MAX_CREW = 6
SEVERITIES = ("Minor", "Serious", "Major", "Fatal")
STEP_NAMES = {1: "Aircraft", 2: "Event", 3: "Causes", 4: "Crew and weather", 5: "Review"}
PHASE_ORDER = ["Taxi", "Takeoff", "Climb", "Cruise", "Descent", "Approach", "Landing"]
FALLBACK = {   # only used when the database has no rows yet to read the choices from
    "phases": PHASE_ORDER,
    "weather": ["Clear", "Rain", "Fog", "Snow", "Storm", "Wind"],
    "roles": ["Pilot", "Co-pilot", "Flight engineer", "Cabin crew"],
    "injuries": ["None", "Minor", "Serious", "Fatal"],
}

# friendly sentences for database error codes -> (step to show them on, sentence)
# A uses 50100-50199.  50110/50111 come from sp_AddIncident (A4), 50101 from the A7 trigger.
FRIENDLY = {
    50101: (4, "More crew are marked Fatal than the number of fatalities. Lower the Fatal crew or raise the fatalities."),
    50110: (3, "Pick at least one cause."),
    50111: (3, "Exactly one cause must be marked as the primary cause."),
}
# 50001-50007 and 50102-50105 are messages written in other triggers; until they are listed here
# the page shows the cleaned database message on the step the keywords point to.
KEYWORD_STEPS = (("uq_incident_event", 2), ("year_built", 2), ("future", 2), ("date", 2),
                 ("cause", 3), ("crew", 4), ("weather", 4), ("visibility", 4),
                 ("wind", 4), ("temperature", 4))

_cache = {}


# ----------------------------------------------------------------- helpers
def _int(v):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return None


def _float(v):
    try:
        return float(str(v).strip())
    except (TypeError, ValueError):
        return None


def _choices(key, sql, order=None):
    """Allowed values are read from the data once (so they always match the table's CHECK rules)."""
    if key not in _cache:
        try:
            vals = [r["v"] for r in query(sql) if r["v"]]
        except Exception:
            vals = []
        vals = vals or list(FALLBACK[key])
        if order:
            vals.sort(key=lambda x: (order.index(x) if x in order else 99, x))
        _cache[key] = vals
    return _cache[key]


def phases():   return _choices("phases", "SELECT DISTINCT phase_of_flight AS v FROM dbo.Incident", PHASE_ORDER)
def weathers(): return _choices("weather", "SELECT DISTINCT condition_type AS v FROM dbo.Weather_Condition")
def roles():    return _choices("roles", "SELECT DISTINCT role_on_flight AS v FROM dbo.Incident_Crew")
def injuries(): return _choices("injuries", "SELECT DISTINCT injury_status AS v FROM dbo.Incident_Crew",
                                ["None", "Minor", "Serious", "Fatal"])


def _state():
    return session.get("wizard") or {}


def _store(w):
    session["wizard"] = w
    session.modified = True


def _raw(step, f):
    """Copy only the expected fields of this step out of the form."""
    if step == 1:
        keys = ("airline_id", "aircraft_id")
    elif step == 2:
        keys = ("incident_date", "airport_id", "airport_label", "location", "phase_of_flight",
                "severity", "fatalities", "injuries", "passengers", "description")
    elif step == 4:
        keys = ("condition_type", "visibility_km", "wind_speed_kmh", "temperature_c") + tuple(
            f"{p}_{i}" for i in range(MAX_CREW) for p in ("crew", "role", "injury"))
    else:
        keys = ()
    d = {k: (f.get(k) or "").strip() for k in keys}
    if step == 3:
        causes = list(f.getlist("causes"))
        prim = list(f.getlist("primary"))
        if not prim and f.get("primary") is not None:
            prim = [f.get("primary")]
        d = {"causes": causes, "primary": prim}
    return d


# --------------------------------------------------------------- validators
def _aircraft(aircraft_id):
    return query("""SELECT a.aircraft_id, a.registration_no AS registration, a.year_built, a.status,
                           a.airline_id, al.name AS airline, t.model
                      FROM dbo.Aircraft a
                      JOIN dbo.Airline al ON al.airline_id = a.airline_id
                      JOIN dbo.Aircraft_Type t ON t.type_id = a.type_id
                     WHERE a.aircraft_id = ?""", (aircraft_id,), one=True)


def _v1(raw, w):
    errs = []
    airline_id, aircraft_id = _int(raw.get("airline_id")), _int(raw.get("aircraft_id"))
    if airline_id is None:
        errs.append("Choose an airline.")
    if aircraft_id is None:
        errs.append("Choose an aircraft.")
    if errs:
        return None, errs
    ac = _aircraft(aircraft_id)
    if not ac or ac["airline_id"] != airline_id:
        return None, ["That aircraft does not belong to the chosen airline."]
    return dict(ac), []


def _v2(raw, w):
    errs = []
    ac, _ = _v1(w.get("d1", {}), w)
    if not ac:
        return None, ["Finish step 1 (aircraft) first."]
    today = dt.date.today()
    try:
        d = dt.date.fromisoformat(raw.get("incident_date", ""))
    except ValueError:
        d = None
        errs.append("Enter a valid incident date.")
    if d:
        if d > today:
            errs.append("The incident date cannot be in the future.")
        elif ac["year_built"] and d.year < ac["year_built"]:
            errs.append(f"The incident date cannot be before the aircraft was built ({ac['year_built']}).")

    airport = None
    aid = _int(raw.get("airport_id"))
    if raw.get("airport_id") and aid is None:
        errs.append("The chosen airport is not valid.")
    elif aid is not None:
        airport = query("SELECT airport_id, name, city, iata_code FROM dbo.Airport WHERE airport_id = ?", (aid,), one=True)
        if not airport:
            errs.append("The chosen airport does not exist.")
    location = raw.get("location", "")
    if not location and airport:
        location = ", ".join(x for x in (airport["name"], airport["city"]) if x)
    if not location:
        errs.append("Choose an airport or type a location.")
    if len(location) > 255:
        errs.append("The location is too long (255 characters at most).")

    phase = raw.get("phase_of_flight", "")
    if phase not in phases():
        errs.append("Choose a phase of flight.")
    severity = raw.get("severity", "")
    if severity not in SEVERITIES:
        errs.append("Choose a severity.")

    fat, inj = _int(raw.get("fatalities") or 0), _int(raw.get("injuries") or 0)
    if fat is None or fat < 0:
        errs.append("Fatalities must be 0 or more.")
    if inj is None or inj < 0:
        errs.append("Injuries must be 0 or more.")
    pax = None
    if raw.get("passengers"):
        pax = _int(raw["passengers"])
        if pax is None or pax < 0 or pax > 32767:
            errs.append("Passengers on board must be a number from 0 to 32767.")
            pax = None
    if fat is not None and fat > 0 and severity and severity != "Fatal":
        errs.append("Only a Fatal incident can have fatalities.")
    # crew is chosen later (step 4), so the limit uses the most crew rows the wizard allows
    if pax is not None and fat is not None and fat > pax + MAX_CREW:
        errs.append(f"Fatalities ({fat}) cannot be more than passengers plus crew ({pax} + up to {MAX_CREW}).")
    desc = raw.get("description", "")
    if len(desc) > 1000:
        errs.append("The description is too long (1000 characters at most).")

    dup_id = None
    if d and phase and not errs:
        dup = query("""SELECT TOP 1 incident_id FROM dbo.Incident
                        WHERE aircraft_id = ? AND incident_date = ? AND phase_of_flight = ?""",
                    (ac["aircraft_id"], d.isoformat(), phase), one=True)
        if dup:
            dup_id = dup["incident_id"]
            errs.append(f"This incident is already recorded (incident #{dup_id}): same aircraft, date and phase of flight.")
    if errs:
        return ({"dup_id": dup_id} if dup_id else None), errs
    return dict(incident_date=d.isoformat(), airport_id=aid, airport_label=raw.get("airport_label", ""),
                location=location, phase_of_flight=phase, severity=severity, fatalities=fat,
                injuries=inj, passengers=pax, description=desc), []


def _cause_rows():
    return query("""SELECT c.cause_id, c.cause_name, ISNULL(cc.category_name, 'Other') AS category_name
                      FROM dbo.Cause c LEFT JOIN dbo.Cause_Category cc ON cc.category_id = c.category_id
                     ORDER BY ISNULL(cc.category_name, 'Other'), c.cause_name""")


def _v3(raw, w):
    errs = []
    valid = {r["cause_id"]: r["cause_name"] for r in _cause_rows()}
    ids = []
    for c in raw.get("causes", []):
        i = _int(c)
        if i is None or i not in valid:
            errs.append("One of the chosen causes is not valid.")
            break
        if i not in ids:
            ids.append(i)
    if not ids and not errs:
        errs.append("Tick at least one cause.")
    prim = raw.get("primary", [])
    prim = prim if isinstance(prim, list) else [prim]
    primary = None
    if ids:
        if len(prim) != 1:
            errs.append("Mark exactly one cause as the primary cause.")
        else:
            primary = _int(prim[0])
            if primary not in ids:
                errs.append("The primary cause must be one of the ticked causes.")
    if errs:
        return None, errs
    return {"causes": [(i, 1 if i == primary else 0) for i in ids],
            "names": {i: valid[i] for i in ids}, "primary": primary}, []


def _crew_rows():
    return query("SELECT crew_id, name FROM dbo.Crew_Member ORDER BY name")


def _v4(raw, w):
    errs = []
    names = {r["crew_id"]: r["name"] for r in _crew_rows()}
    crew, seen = [], set()
    for i in range(MAX_CREW):
        cid_raw = raw.get(f"crew_{i}", "")
        if not cid_raw:
            continue
        cid = _int(cid_raw)
        role, inj = raw.get(f"role_{i}", ""), raw.get(f"injury_{i}", "")
        if cid is None or cid not in names:
            errs.append(f"Crew row {i + 1}: choose a crew member from the list.")
        elif cid in seen:
            errs.append(f"Crew row {i + 1}: {names[cid]} is listed twice.")
        else:
            seen.add(cid)
        if not role or role not in roles():
            errs.append(f"Crew row {i + 1}: choose a role on the flight.")
        if not inj or inj not in injuries():
            errs.append(f"Crew row {i + 1}: choose an injury status.")
        crew.append((cid, role, inj))
    ctype = raw.get("condition_type", "")
    vis, wind, temp = raw.get("visibility_km", ""), raw.get("wind_speed_kmh", ""), raw.get("temperature_c", "")
    weather = None
    if ctype or vis or wind or temp:
        if not ctype or ctype not in weathers():
            errs.append("Choose the weather type (or clear the weather numbers).")
        v = _float(vis) if vis else None
        wd = _int(wind) if wind else None
        t = _int(temp) if temp else None
        if vis and (v is None or not 0 <= v <= 1000):
            errs.append("Visibility must be a number from 0 to 1000 km.")
        if wind and (wd is None or not 0 <= wd <= 500):
            errs.append("Wind speed must be a whole number from 0 to 500 km/h.")
        if temp and (t is None or not -90 <= t <= 60):
            errs.append("Temperature must be a whole number from -90 to 60 C.")
        weather = (ctype, v, wd, t)
    if errs:
        return None, errs
    return {"crew": crew, "crew_names": names, "weather": weather}, []


VALIDATORS = {1: _v1, 2: _v2, 3: _v3, 4: _v4}


def _validate_all(w):
    """Re-check every draft. Returns (data, first_failing_step, errors)."""
    data = {}
    for s in (1, 2, 3, 4):
        clean_data, errs = VALIDATORS[s](w.get(f"d{s}", {}), w)
        if errs:
            return None, s, errs
        data[s] = clean_data
    return data, None, []


# ------------------------------------------------------------- the database
def _submit(data):
    ac, ev, ca, cr = data[1], data[2], data[3], data[4]
    sql = ["SET NOCOUNT ON;", "DECLARE @c dbo.CauseList, @w dbo.CrewList, @id INT;"]
    params = []
    sql.append("INSERT @c (cause_id, is_primary) VALUES " + ",".join(["(?,?)"] * len(ca["causes"])) + ";")
    for cid, prim in ca["causes"]:
        params += [cid, prim]
    if cr["crew"]:
        sql.append("INSERT @w (crew_id, role_on_flight, injury_status) VALUES " + ",".join(["(?,?,?)"] * len(cr["crew"])) + ";")
        for row in cr["crew"]:
            params += list(row)
    wtr = cr["weather"] or (None, None, None, None)
    sql.append("""EXEC dbo.sp_AddIncident @aircraft_id=?, @incident_date=?, @location=?, @airport_id=?, @flight_id=NULL,
        @phase_of_flight=?, @severity=?, @fatalities=?, @injuries=?, @passengers=?, @description=?, @recorded_by=?,
        @causes=@c, @crew=@w, @condition_type=?, @visibility_km=?, @wind_speed_kmh=?, @temperature_c=?,
        @new_id=@id OUTPUT;""")
    params += [ac["aircraft_id"], ev["incident_date"], ev["location"], ev["airport_id"], ev["phase_of_flight"],
               ev["severity"], ev["fatalities"], ev["injuries"], ev["passengers"], ev["description"] or None,
               session.get("username"), wtr[0], wtr[1], wtr[2], wtr[3]]
    sql.append("SELECT @id AS new_id;")
    c = conn()
    try:
        cur = c.cursor()
        cur.execute("\n".join(sql), params)
        new_id = None
        while True:
            try:
                row = cur.fetchone()
            except pyodbc.ProgrammingError:
                row = None
            if row is not None:
                new_id = row[0]
                break
            if not cur.nextset():
                break
        c.commit()
        return new_id
    except Exception:
        try:
            c.rollback()
        except Exception:
            pass
        raise
    finally:
        c.close()


def _friendly(exc):
    text = str(exc)
    m = re.search(r"\((\d{5})\)", text)
    code = int(m.group(1)) if m else None
    if code in FRIENDLY:
        return FRIENDLY[code]
    low = text.lower()
    if "uq_incident_event" in low:
        return 2, "This incident is already recorded: same aircraft, date and phase of flight."
    for word, step in KEYWORD_STEPS:
        if word in low:
            return step, f"Database rejected this: {clean(exc)}"
    return 5, f"Database rejected this: {clean(exc)}"


# ------------------------------------------------------------------- routes
def _render(step, raw, errors=(), data=None, dup_id=None):
    ctx = dict(step=step, step_names=STEP_NAMES, raw=raw, errors=list(errors), dup_id=dup_id,
               today=dt.date.today().isoformat(), phases=phases(), severities=SEVERITIES, summary=data)
    if step == 1:
        ctx["airlines"] = query("SELECT airline_id, name FROM dbo.Airline ORDER BY name")
    elif step == 3:
        groups = {}
        for r in _cause_rows():
            groups.setdefault(r["category_name"], []).append(r)
        ctx["groups"] = groups
    elif step == 4:
        ctx.update(crew_list=_crew_rows(), roles=roles(), injuries=injuries(), weathers=weathers(), max_crew=MAX_CREW)
    return render_template("wizard.html", **ctx)


def wizard_step(step):
    if step not in STEP_NAMES:
        abort(404)
    if request.args.get("new") == "1":
        session.pop("wizard", None)
        return redirect(url_for("wizard_step", step=1))
    w = _state()
    ok = set(w.get("ok", []))
    for s in range(1, step):                       # cannot jump ahead of unfinished steps
        if s not in ok and f"d{s}" not in w:
            flash(f"Please finish step {s} ({STEP_NAMES[s]}) first.", "warning")
            return redirect(url_for("wizard_step", step=s))

    if step == 5:
        data, bad_step, errs = _validate_all(w)
        if request.method == "POST":
            if bad_step:
                flash("; ".join(errs), "danger")
                return redirect(url_for("wizard_step", step=bad_step))
            try:
                new_id = _submit(data)
            except pyodbc.Error as e:
                s, msg = _friendly(e)
                flash(msg, "danger")
                return redirect(url_for("wizard_step", step=s))
            session.pop("wizard", None)
            flash(f"Incident #{new_id} saved.", "success")
            return redirect(url_for("incident_detail", iid=new_id))
        if bad_step:
            flash("; ".join(errs), "danger")
            return redirect(url_for("wizard_step", step=bad_step))
        return _render(5, {}, data=data)

    if request.method == "POST":
        raw = _raw(step, request.form)
        w[f"d{step}"] = raw
        data, errs = VALIDATORS[step](raw, w)
        action = request.form.get("action", "next")
        was_ok = step in ok
        if errs:
            ok.discard(step)
        else:
            ok.add(step)
            old = (w.get("_aircraft") if step == 1 else None)
            if step == 1:                          # a different aircraft makes the date check stale
                if old is not None and old != data["aircraft_id"]:
                    ok.discard(2)
                w["_aircraft"] = data["aircraft_id"]
        w["ok"] = sorted(ok)
        _store(w)
        if action == "back":
            return redirect(url_for("wizard_step", step=max(1, step - 1)))
        if errs:
            flash("; ".join(errs), "danger")
            dup = data.get("dup_id") if isinstance(data, dict) else None
            return _render(step, raw, errs, dup_id=dup)
        return redirect(url_for("wizard_step", step=step + 1))

    return _render(step, w.get(f"d{step}", {}))


def wizard_aircraft():
    airline_id = _int(request.args.get("airline_id"))
    if airline_id is None:
        return jsonify([])
    rows = query("""SELECT a.aircraft_id, a.registration_no AS registration, a.status, a.year_built, t.model
                      FROM dbo.Aircraft a JOIN dbo.Aircraft_Type t ON t.type_id = a.type_id
                     WHERE a.airline_id = ? ORDER BY a.registration_no""", (airline_id,))
    return jsonify([dict(r) for r in rows])


def wizard_airports():
    q = (request.args.get("q") or "").strip()
    if len(q) < 2:
        return jsonify([])
    esc = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_").replace("[", "\\[")
    like = f"%{esc}%"
    rows = query("""SELECT TOP 10 airport_id, iata_code, name, city, country FROM dbo.Airport
                     WHERE name LIKE ? ESCAPE '\\' OR city LIKE ? ESCAPE '\\' OR iata_code = ? OR icao_code = ?
                     ORDER BY name""", (like, like, q, q))
    return jsonify([dict(r) for r in rows])


def register(app, perms):
    for ep in ("wizard_step", "wizard_aircraft", "wizard_airports"):
        perms[ep] = EDITORS
    app.add_url_rule("/incident/new/<int:step>", "wizard_step", wizard_step, methods=["GET", "POST"])
    app.add_url_rule("/incident/new/aircraft", "wizard_aircraft", wizard_aircraft)
    app.add_url_rule("/incident/new/airports", "wizard_airports", wizard_airports)
