from markupsafe import Markup
from flask import Flask, render_template, request, redirect, url_for, flash, session
from werkzeug.security import check_password_hash, generate_password_hash
import pyodbc
import datetime as dt
from db import query, execute, clean, conn
from reports_sql import REPORTS

app = Flask(__name__)
app.secret_key = "blackboxdb-dev"

ALL = ("Admin", "Investigator", "Officer", "Airline")
STAFF = ("Admin", "Investigator", "Officer")
EDITORS = ("Admin", "Investigator")
PERMS = {   # endpoint -> roles allowed (anything not listed is open to every logged-in role)
    "dashboard": STAFF, "investigators": STAFF, "investigator_detail": STAFF, "reports": STAFF, "audit": STAFF,
    "admin": ("Admin",), "admin_add": ("Admin",), "admin_user": ("Admin",),
    "incident_new": EDITORS, "incident_edit": EDITORS, "investigation_open": EDITORS,
    "investigation_end": EDITORS, "recommendation_issue": EDITORS,
    "recommendation_close": ("Admin", "Officer", "Airline"),
}

def home_url():
    return url_for("recommendations") if session.get("role") == "Airline" else url_for("dashboard")

@app.before_request
def guard():
    ep = request.endpoint
    if ep in (None, "static", "login"):
        return None
    if "user_id" not in session:
        return redirect(url_for("login", next=request.path))
    if session["role"] not in PERMS.get(ep, ALL):
        if ep != "dashboard":
            flash("Your role is not allowed to do that", "danger")
        return redirect(home_url())

@app.context_processor
def inject_user():
    r = session.get("role")
    return dict(role=r, full_name=session.get("full_name"), airline_name=session.get("airline_name"),
                can_edit=r in EDITORS, can_close=r in ("Admin", "Officer", "Airline"))

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        u = query("""SELECT u.*, al.name AS airline_name FROM Users u
                     LEFT JOIN Airline al ON al.airline_id = u.airline_id WHERE u.username = ?""",
                  (request.form["username"].strip(),), one=True)
        if u and check_password_hash(u["password_hash"], request.form["password"]):
            session.clear()
            session.update(user_id=u["user_id"], username=u["username"], full_name=u["full_name"],
                           role=u["role"], airline_id=u["airline_id"], airline_name=u["airline_name"])
            nxt = request.args.get("next", "")
            return redirect(nxt if nxt.startswith("/") and not nxt.startswith("//") else home_url())
        flash("Wrong username or password", "danger")
    return render_template("login.html")

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


def run(fn, ok_msg, *args):
    """Run a DB write; show trigger/constraint errors as a red alert."""
    try:
        fn(*args); flash(ok_msg, "success"); return True
    except pyodbc.Error as e:
        if "uq_incident_event" in str(e):          # same aircraft + date + phase already recorded
            f = request.form
            old = query("SELECT incident_id FROM Incident WHERE aircraft_id=? AND incident_date=? AND phase_of_flight=?",
                        (f.get("aircraft_id"), f.get("incident_date"), f.get("phase_of_flight")), one=True)
            link = Markup(f' (<a href="/incident/{int(old["incident_id"])}">incident #{int(old["incident_id"])}</a>)') if old else ""
            flash(Markup("This incident is already recorded: same aircraft, date and phase of flight") + link +
                  Markup(". Open the existing record instead of adding it again."), "danger")
        else:
            flash(f"Database rejected this: {clean(e)}", "danger")
        return False

# dashboard route is now owned by charts_routes (A11 interactive dashboard)

@app.route("/incidents")
def incidents():
    f = {k: request.args.get(k, "") for k in ("airline", "type", "year", "severity")}
    if session["role"] == "Airline":            # an airline only ever sees its own incidents
        f["airline"] = str(session["airline_id"])
    sql = """SELECT TOP 300 i.*, a.registration_no AS registration, al.name airline, t.model
             FROM Incident i JOIN Aircraft a ON a.aircraft_id=i.aircraft_id
             JOIN Airline al ON al.airline_id=a.airline_id
             JOIN Aircraft_Type t ON t.type_id=a.type_id WHERE 1=1"""
    args = []
    for col, key in (("al.airline_id","airline"),("t.type_id","type"),("YEAR(i.incident_date)","year"),("i.severity","severity")):
        if f[key]: sql += f" AND {col}=?"; args.append(f[key])
    rows = query(sql + " ORDER BY i.incident_date DESC", args)
    return render_template("incidents.html", rows=rows, f=f,
        airlines=query("SELECT * FROM Airline ORDER BY name"),
        types=query("SELECT * FROM Aircraft_Type ORDER BY model"),
        years=query("SELECT DISTINCT YEAR(incident_date) AS y FROM Incident ORDER BY y DESC"))

@app.route("/incident/<int:iid>")
def incident_detail(iid):
    inc = query("""SELECT i.*, a.registration_no AS registration, al.name airline, a.airline_id, t.model FROM Incident i
        JOIN Aircraft a ON a.aircraft_id=i.aircraft_id JOIN Airline al ON al.airline_id=a.airline_id
        JOIN Aircraft_Type t ON t.type_id=a.type_id WHERE i.incident_id=?""", (iid,), one=True)
    if not inc: return "Incident not found", 404
    if session["role"] == "Airline" and inc["airline_id"] != session["airline_id"]:
        flash("You can only open incidents that involve your own airline", "danger")
        return redirect(url_for("incidents"))
    return render_template("incident_detail.html", inc=inc,
        investigators=query("SELECT * FROM Investigator ORDER BY name"),
        airlines=query("SELECT * FROM Airline ORDER BY name"),
        causes=query("SELECT c.cause_name AS name, c.category, ic.is_primary FROM Incident_Cause ic JOIN Cause c ON c.cause_id=ic.cause_id WHERE incident_id=?", (iid,)),
        weather=query("SELECT * FROM Weather_Condition WHERE incident_id=?", (iid,), one=True),
        crew=query("SELECT cm.name AS full_name, ic.role_on_flight, ic.injury_status FROM Incident_Crew ic JOIN Crew_Member cm ON cm.crew_id=ic.crew_id WHERE incident_id=?", (iid,)),
        inv=query("SELECT inv.*, i.name AS full_name FROM Investigation inv JOIN Investigator i ON i.investigator_id=inv.lead_investigator_id WHERE inv.incident_id=?", (iid,), one=True),
        recs=query("SELECT r.*, al.name airline FROM Safety_Recommendation r JOIN Airline al ON al.airline_id=r.airline_id WHERE r.incident_id=?", (iid,)))

def form_data():
    f = request.form
    return (f["aircraft_id"], f["incident_date"], f["location"].strip(), f["phase_of_flight"],
            f["severity"], int(f["fatalities"] or 0), int(f["injuries"] or 0), f["description"].strip())

def valid(d):
    if not d[2]: flash("Location is required", "danger"); return False
    if d[5] < 0 or d[6] < 0: flash("Fatalities and injuries cannot be negative", "danger"); return False
    if d[4] != "Fatal" and d[5] > 0: flash("Only 'Fatal' incidents can have fatalities", "danger"); return False
    return True

AIRCRAFT_SQL = "SELECT a.aircraft_id, a.registration_no AS registration, al.name airline FROM Aircraft a JOIN Airline al ON al.airline_id=a.airline_id ORDER BY a.registration_no"

CAUSES_SQL = "SELECT * FROM Cause ORDER BY cause_name"

def parse_children():
    f = request.form
    causes = [int(x) for x in f.getlist("causes")]
    primary = int(f["primary_cause"]) if f.get("primary_cause") else None
    weather = None
    if f.get("condition_type"):
        num = lambda k, cast: cast(f[k]) if f.get(k) else None
        weather = (f["condition_type"], num("visibility_km", float), num("wind_speed_kmh", int), num("temperature_c", int))
    crew = [(int(f[f"crew_{i}"]), f[f"role_{i}"], f[f"injury_{i}"]) for i in range(4) if f.get(f"crew_{i}")]
    return causes, primary, weather, crew

def valid_children(causes, primary, crew):
    if not causes: flash("Pick at least one cause", "danger"); return False
    if primary not in causes: flash("The primary cause must be one of the ticked causes", "danger"); return False
    if len({c[0] for c in crew}) < len(crew): flash("A crew member is listed twice", "danger"); return False
    return True

def create_incident(d, causes, primary, weather, crew):
    """Incident + causes + weather + crew in ONE transaction: any trigger error rolls everything back."""
    c = conn(); cur = c.cursor()
    try:
        cur.execute("""SET NOCOUNT ON;
            INSERT INTO Incident(aircraft_id,incident_date,location,phase_of_flight,severity,fatalities,injuries,description,recorded_by)
            VALUES(?,?,?,?,?,?,?,?,?); SELECT SCOPE_IDENTITY();""", d + (session.get("username"),))
        iid = int(cur.fetchone()[0])
        for cid in causes:
            cur.execute("INSERT INTO Incident_Cause(incident_id,cause_id,is_primary) VALUES(?,?,?)", (iid, cid, 1 if cid == primary else 0))
        if weather:
            cur.execute("INSERT INTO Weather_Condition(incident_id,condition_type,visibility_km,wind_speed_kmh,temperature_c) VALUES(?,?,?,?,?)", (iid,) + weather)
        for cid, role, inj in crew:
            cur.execute("INSERT INTO Incident_Crew(incident_id,crew_id,role_on_flight,injury_status) VALUES(?,?,?,?)", (iid, cid, role, inj))
        c.commit()
    finally:
        cur.close(); c.close()

@app.route("/incident/new", methods=["GET", "POST"])
def incident_new():
    return redirect(url_for("wizard_step", step=1, new=1))
    if request.method == "POST":
        d = form_data(); causes, primary, weather, crew = parse_children()
        if valid(d) and valid_children(causes, primary, crew) and \
           run(create_incident, "Incident added", d, causes, primary, weather, crew):
            return redirect(url_for("incidents"))
    return render_template("incident_form.html", inc=request.form or {}, edit=False, aircraft=query(AIRCRAFT_SQL),
        causes=query(CAUSES_SQL), crew=query("SELECT * FROM Crew_Member ORDER BY name"),
        sel_causes=request.form.getlist("causes"))

@app.route("/incident/<int:iid>/edit", methods=["GET", "POST"])
def incident_edit(iid):
    if request.method == "POST":
        d = form_data()
        if valid(d) and run(lambda: execute("""UPDATE Incident SET aircraft_id=?,incident_date=?,location=?,
              phase_of_flight=?,severity=?,fatalities=?,injuries=?,description=? WHERE incident_id=?""", d + (iid,)), "Incident updated"):
            return redirect(url_for("incident_detail", iid=iid))
    inc = request.form or query("SELECT * FROM Incident WHERE incident_id=?", (iid,), one=True)
    return render_template("incident_form.html", inc=inc, aircraft=query(AIRCRAFT_SQL), edit=True)

@app.route("/incident/<int:iid>/investigation", methods=["POST"])
def investigation_open(iid):
    inc = query("SELECT incident_date FROM Incident WHERE incident_id=?", (iid,), one=True)
    start = request.form["start_date"]
    if start < str(inc["incident_date"]):
        flash("An investigation cannot start before the incident date", "danger")
    else:
        run(lambda: execute("INSERT INTO Investigation(incident_id,lead_investigator_id,start_date) VALUES(?,?,?)",
            (iid, request.form["lead_investigator_id"], start)), "Investigation opened - incident is now Under Investigation")
    return redirect(url_for("incident_detail", iid=iid))

@app.route("/incident/<int:iid>/recommendation", methods=["POST"])
def recommendation_issue(iid):
    f = request.form
    if f["due_date"] < dt.date.today().isoformat():
        flash("The due date cannot be in the past", "danger")
    else:
        run(lambda: execute("""INSERT INTO Safety_Recommendation(incident_id,airline_id,rec_text,issued_date,due_date)
            VALUES(?,?,?,CAST(GETDATE() AS DATE),?)""", (iid, f["airline_id"], f["rec_text"].strip(), f["due_date"])),
            "Recommendation issued")
    return redirect(url_for("incident_detail", iid=iid))

@app.route("/investigation/<int:inv_id>/end", methods=["POST"])
def investigation_end(inv_id):
    row = query("SELECT incident_id FROM Investigation WHERE investigation_id=?", (inv_id,), one=True)
    run(lambda: execute("UPDATE Investigation SET end_date=?, probable_cause_summary=? WHERE investigation_id=?",
        (request.form["end_date"], request.form["findings"], inv_id)), "Investigation ended - incident closed by trigger")
    return redirect(url_for("incident_detail", iid=row["incident_id"]))

@app.route("/recommendations")
def recommendations():
    rows = query("""SELECT r.*, al.name AS airline,
                    CASE WHEN r.status='Open' AND r.due_date < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS overdue
                    FROM Safety_Recommendation r JOIN Airline al ON al.airline_id=r.airline_id
                    ORDER BY r.status, r.due_date""")
    if session["role"] == "Airline":
        rows = [r for r in rows if r["airline_id"] == session["airline_id"]]
    return render_template("recommendations.html", rows=rows)

@app.route("/recommendations/<int:rid>/close", methods=["POST"])
def recommendation_close(rid):
    if session["role"] == "Airline":
        own = query("SELECT airline_id FROM Safety_Recommendation WHERE rec_id=?", (rid,), one=True)
        if not own or own["airline_id"] != session["airline_id"]:
            flash("You can only respond to recommendations addressed to your airline", "danger")
            return redirect(url_for("recommendations"))
    run(lambda: execute("UPDATE Safety_Recommendation SET status='Closed', response_text=? WHERE rec_id=?",
        (request.form["response_text"], rid)), "Recommendation closed")
    return redirect(request.referrer or url_for("recommendations"))

@app.route("/audit")
def audit():
    return render_template("audit.html", rows=query("SELECT TOP 200 * FROM Audit_Log ORDER BY log_id DESC"))

@app.route("/reports")
def reports():
    out = []
    for title, sql in REPORTS:
        rows = query(sql)
        out.append((title, list(rows[0].keys()) if rows else [], rows))
    return render_template("reports.html", reports=out,
        airlines=query("SELECT * FROM v_airline_safety_summary ORDER BY unresolved_recs DESC"))

@app.route("/investigators")
def investigators():
    rows = query("""SELECT i.investigator_id, i.name, i.agency, i.specialization,
        COUNT(inv.investigation_id) AS total,
        SUM(CASE WHEN inv.investigation_id IS NOT NULL AND inv.end_date IS NULL THEN 1 ELSE 0 END) AS open_cases,
        CAST(AVG(CAST(DATEDIFF(day, inv.start_date, inv.end_date) AS FLOAT)) AS DECIMAL(10,1)) AS avg_days
        FROM Investigator i LEFT JOIN Investigation inv ON inv.lead_investigator_id = i.investigator_id
        GROUP BY i.investigator_id, i.name, i.agency, i.specialization ORDER BY total DESC, i.name""")
    return render_template("investigators.html", rows=rows)

@app.route("/investigators/<int:vid>")
def investigator_detail(vid):
    person = query("SELECT * FROM Investigator WHERE investigator_id=?", (vid,), one=True)
    if not person: return "Investigator not found", 404
    cases = query("""SELECT inv.investigation_id, inv.incident_id, inv.start_date, inv.end_date,
        i.severity, i.location, i.status, al.name AS airline
        FROM Investigation inv JOIN Incident i ON i.incident_id = inv.incident_id
        JOIN Aircraft a ON a.aircraft_id = i.aircraft_id JOIN Airline al ON al.airline_id = a.airline_id
        WHERE inv.lead_investigator_id = ? ORDER BY inv.start_date DESC""", (vid,))
    return render_template("investigator_detail.html", p=person, cases=cases)

ADMIN_SQL = {
 "airline": ("INSERT INTO Airline(name,country,iata_code) VALUES(?,?,?)", ("name", "country", "iata_code")),
 "aircraft": ("INSERT INTO Aircraft(registration_no,airline_id,type_id,year_built) VALUES(?,?,?,?)", ("registration_no", "airline_id", "type_id", "year_built")),
 "investigator": ("INSERT INTO Investigator(name,agency,specialization) VALUES(?,?,?)", ("name", "agency", "specialization")),
}

@app.route("/admin")
def admin():
    return render_template("admin.html", airlines=query("SELECT * FROM Airline ORDER BY name"),
        users=query("""SELECT u.username, u.full_name, u.role, al.name AS airline FROM Users u
                       LEFT JOIN Airline al ON al.airline_id = u.airline_id ORDER BY u.role, u.username"""),
        types=query("SELECT * FROM Aircraft_Type ORDER BY model"),
        n_aircraft=query("SELECT COUNT(*) AS n FROM Aircraft", one=True)["n"],
        n_inv=query("SELECT COUNT(*) AS n FROM Investigator", one=True)["n"])

@app.route("/admin/add/<kind>", methods=["POST"])
def admin_add(kind):
    if kind not in ADMIN_SQL: return "Unknown form", 404
    sql, fields = ADMIN_SQL[kind]
    vals = [request.form[f].strip() for f in fields]
    run(lambda: execute(sql, vals), f"{kind.title()} added")
    return redirect(url_for("admin"))

@app.route("/admin/user", methods=["POST"])
def admin_user():
    f = request.form
    airline = f.get("airline_id") or None
    if f["role"] != "Airline":
        airline = None
    if len(f["password"]) < 6:
        flash("Password must be at least 6 characters", "danger")
    else:
        run(lambda: execute("INSERT INTO Users(username,full_name,password_hash,role,airline_id) VALUES(?,?,?,?,?)",
            (f["username"].strip(), f["full_name"].strip(), generate_password_hash(f["password"], method="pbkdf2:sha256"),
             f["role"], airline)), "User created")
    return redirect(url_for("admin"))
import import_routes
import_routes.register(app, PERMS)
import queries_routes
queries_routes.register(app, PERMS)
import wizard_routes
wizard_routes.register(app, PERMS)
import charts_routes
charts_routes.register(app, PERMS)
if __name__ == "__main__":
    app.run(debug=True)
