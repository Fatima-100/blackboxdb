"""test_wizard.py - A10: 5 scenarios for the incident wizard, run against your real database.
Usage (project folder, database running, wizard wired into app.py):  python test_wizard.py
The success scenario saves ONE test incident (description starts with WIZTEST) and removes it again.
(If the A7 soft-delete trigger is installed the row stays with is_deleted = 1; that is harmless.)"""
import datetime as dt
import re

from app import app
from db import execute, query

app.config["TESTING"] = True
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name + (f"   [{detail}]" if detail and not ok else ""))


def new_client():
    c = app.test_client()
    with c.session_transaction() as s:
        s.update(user_id=1, username="admin", full_name="Wizard Test", role="Admin", airline_id=None, airline_name=None)
    return c


def text(r):
    return r.get_data(as_text=True)


# ---- pick real data from the database
ac = query("""SELECT TOP 1 aircraft_id, airline_id FROM Aircraft
               WHERE status = 'Active' AND year_built <= 2015 ORDER BY aircraft_id""", one=True)
causes = [r["cause_id"] for r in query("SELECT TOP 2 cause_id FROM Cause ORDER BY cause_id")]
crew = [r["crew_id"] for r in query("SELECT TOP 2 crew_id FROM Crew_Member ORDER BY crew_id")]
cr = query("SELECT TOP 1 role_on_flight, injury_status FROM Incident_Crew", one=True)
phase = query("SELECT TOP 1 phase_of_flight AS p FROM Incident GROUP BY phase_of_flight ORDER BY COUNT(*) DESC", one=True)["p"]
day = dt.date(2024, 12, 31)
while query("SELECT 1 AS x FROM Incident WHERE aircraft_id=? AND incident_date=? AND phase_of_flight=?",
            (ac["aircraft_id"], day.isoformat(), phase), one=True):
    day -= dt.timedelta(days=1)                      # find a free date so the unique rule is not hit

S1 = {"airline_id": str(ac["airline_id"]), "aircraft_id": str(ac["aircraft_id"]), "action": "next"}
S2 = {"incident_date": day.isoformat(), "phase_of_flight": phase, "severity": "Minor", "location": "WIZTEST location",
      "fatalities": "0", "injuries": "1", "passengers": "120", "description": "WIZTEST wizard incident", "action": "next"}
S3 = {"causes": [str(c) for c in causes], "primary": str(causes[0]), "action": "next"}
S4 = {"crew_0": str(crew[0]), "role_0": cr["role_on_flight"], "injury_0": cr["injury_status"],
      "crew_1": str(crew[1]), "role_1": cr["role_on_flight"], "injury_1": "None",
      "condition_type": query("SELECT TOP 1 condition_type AS t FROM Weather_Condition", one=True)["t"],
      "visibility_km": "8", "wind_speed_kmh": "20", "temperature_c": "15", "action": "next"}

# ---- 1. full success
c = new_client()
c.get("/incident/new/1?new=1")
r1 = [c.post("/incident/new/1", data=S1), c.post("/incident/new/2", data=S2),
      c.post("/incident/new/3", data=S3), c.post("/incident/new/4", data=S4)]
check("1a. steps 1-4 accepted", all(r.status_code == 302 for r in r1), [r.status_code for r in r1])
check("1b. review page shows the answers", "WIZTEST location" in text(c.get("/incident/new/5")))
# 1c — only count live rows (adjust if your column is named differently)
before = query(
    """SELECT COUNT(*) AS n FROM Incident
       WHERE description LIKE 'WIZTEST%'
         AND ISNULL(is_deleted, 0) = 0""",
    one=True,
)["n"]
check("1c. nothing is saved before Submit", before == 0, before)
r = c.post("/incident/new/5")
loc = r.headers.get("Location", "")
new_id = int(loc.rstrip("/").split("/")[-1]) if loc.rstrip("/").split("/")[-1].isdigit() else None
check("1d. Submit redirects to the new incident", r.status_code == 302 and new_id is not None, loc)
if new_id:
    n = query("""SELECT (SELECT COUNT(*) FROM Incident_Cause WHERE incident_id=?) AS c,
                        (SELECT COUNT(*) FROM Incident_Crew  WHERE incident_id=?) AS m,
                        (SELECT COUNT(*) FROM Weather_Condition WHERE incident_id=?) AS w""", (new_id, new_id, new_id), one=True)
    check("1e. incident saved with 2 causes, 2 crew, 1 weather", (n["c"], n["m"], n["w"]) == (2, 2, 1), dict(n))

    
    execute("DELETE FROM Incident WHERE incident_id=?", (new_id,))
check("1f. session cleared after Submit", c.get("/incident/new/3").status_code == 302)

# ---- 2. future date rejected
c = new_client(); c.get("/incident/new/1?new=1"); c.post("/incident/new/1", data=S1)
tomorrow = (dt.date.today() + dt.timedelta(days=1)).isoformat()
r = c.post("/incident/new/2", data={**S2, "incident_date": tomorrow})
check("2. future date rejected, stays on step 2", r.status_code == 200 and "future" in text(r))

from werkzeug.datastructures import MultiDict   # top of file is fine

# ---- 3. two primary causes rejected
c = new_client(); c.get("/incident/new/1?new=1"); c.post("/incident/new/1", data=S1); c.post("/incident/new/2", data=S2)
two_primary = MultiDict(
    [("causes", str(causes[0])), ("causes", str(causes[1])),
     ("primary", str(causes[0])), ("primary", str(causes[1])),
     ("action", "next")]
)
r = c.post("/incident/new/3", data=two_primary)
body = text(r).lower()
check("3. two primary causes rejected",
      r.status_code == 200 and "exactly one" in body,
      f"status={r.status_code} body_snip={body[:300]!r}")

# ---- 4. going back and changing an answer keeps the others
c = new_client(); c.get("/incident/new/1?new=1")
c.post("/incident/new/1", data=S1); c.post("/incident/new/2", data=S2); c.post("/incident/new/3", data=S3)
c.post("/incident/new/3", data={**S3, "action": "back"})
c.post("/incident/new/2", data={**S2, "injuries": "7", "action": "back"})
p2 = text(c.get("/incident/new/2"))
p3 = text(c.get("/incident/new/3"))
cause_ok = re.search(rf'id="c{causes[0]}"[^>]*\bchecked\b', p3) is not None
check("4. back + change: new value kept, other answers kept",
      'value="7"' in p2 and "WIZTEST location" in p2 and cause_ok,
      f"inj7={'value=\"7\"' in p2} loc={'WIZTEST location' in p2} cause_checked={cause_ok}")

# ---- 5. refresh on step 3 does not lose data
c = new_client(); c.get("/incident/new/1?new=1")
c.post("/incident/new/1", data=S1); c.post("/incident/new/2", data=S2); c.post("/incident/new/3", data=S3)
a = text(c.get("/incident/new/3"))
b = text(c.get("/incident/new/3"))
def causes_checked(html):
    return all(re.search(rf'id="c{cid}"[^>]*\bchecked\b', html) for cid in causes)
check("5. refresh step 3 keeps the ticked causes",
      causes_checked(a) and causes_checked(b),
      f"a_ok={causes_checked(a)} b_ok={causes_checked(b)}")

print(f"\n{sum(results)} of {len(results)} checks passed" + ("  -> ALL PASS" if all(results) else "  -> see FAIL lines"))
