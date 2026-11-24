"""Generates SIMULATED data (about 150 incidents + related rows). Run once after schema.sql."""
import random, re, datetime as dt
from werkzeug.security import generate_password_hash
from db import conn
random.seed(42)
today = dt.date.today()
c = conn(); cur = c.cursor()
cur.execute("EXEC sp_set_session_context @key = N'app_user', @value = N'seed script'")

def ins(sql, args):
    """Insert into an IDENTITY table and return the new id (same batch, so SCOPE_IDENTITY works)."""
    cur.execute("SET NOCOUNT ON; " + sql + "; SELECT SCOPE_IDENTITY();", args)
    return int(cur.fetchone()[0])
def ex(sql, args): cur.execute(sql, args)

airlines = [("Skyline Air","Pakistan","SK"),("Meridian Airways","UAE","MD"),("Nordic Wings","Norway","NW"),
 ("Pacific Crest","USA","PC"),("Andes Connect","Peru","AC"),("Sahara Jet","Egypt","SJ"),
 ("Baltic Air","Latvia","BA"),("Kiwi Regional","New Zealand","KR"),("Gulf Horizon","Qatar","GH"),("Alpine Air","Switzerland","AL")]
a_ids = [ins("INSERT INTO Airline(name,country,iata_code) VALUES(?,?,?)", a) for a in airlines]

types = [("Boeing","737-800","Narrow-body"),("Airbus","A320-200","Narrow-body"),("ATR","72-600","Turboprop"),
 ("Embraer","E175","Regional jet"),("Cessna","172","Light"),("Boeing","777-300ER","Wide-body"),
 ("Airbus","A330-300","Wide-body"),("De Havilland","Dash 8 Q400","Turboprop")]
t_ids = [ins("INSERT INTO Aircraft_Type(manufacturer,model,category) VALUES(?,?,?)", t) for t in types]

causes = [("Engine failure","Mechanical"),("Hydraulic failure","Mechanical"),("Landing gear malfunction","Mechanical"),
 ("Pilot error","Human factors"),("Crew fatigue","Human factors"),("Miscommunication with ATC","Human factors"),
 ("Bird strike","Environmental"),("Windshear","Weather"),("Icing","Weather"),("Low visibility","Weather"),
 ("Runway incursion","Operational"),("Maintenance error","Maintenance")]
c_ids = [ins("INSERT INTO Cause(cause_name,category) VALUES(?,?)", x) for x in causes]

inv_names = ["Amna Rauf","David Clarke","Sofia Marin","Hamza Qureshi","Lena Berg","Tariq Aziz"]
specs = ["Powerplant","Human factors","Structures","Avionics","Operations","Meteorology"]
inv_ids = [ins("INSERT INTO Investigator(name,agency,specialization) VALUES(?,?,?)",
          (n,"Aviation Safety Board",specs[i])) for i, n in enumerate(inv_names)]
crew_ids = [ins("INSERT INTO Crew_Member(name,role,license_no,experience_years) VALUES(?,?,?,?)",
           (f"Crew Member {i}", random.choice(["Captain","First Officer","Flight Attendant","Flight Engineer"]),
            f"LIC-{1000+i}", random.randint(1,30))) for i in range(1,41)]

cat_of = {t_ids[i]: types[i][2] for i in range(len(types))}
CAP = {'Light': 4, 'Turboprop': 78, 'Regional jet': 88, 'Narrow-body': 190, 'Wide-body': 400}   # rough passenger+crew limits
ac_ids, airline_of, ac_year, ac_cap = [], {}, {}, {}
for i in range(40):          # first 5 aircraft belong to airline 1 and are old enough for any incident
    al = a_ids[0] if i < 5 else random.choice(a_ids)
    tid = random.choice(t_ids)
    yb = random.randint(1998, 2010) if i < 5 else random.randint(1998, 2022)
    aid = ins("INSERT INTO Aircraft(registration_no,airline_id,type_id,year_built) VALUES(?,?,?,?)",
              (f"AP-{100+i}", al, tid, yb))
    ac_ids.append(aid); airline_of[aid] = al; ac_year[aid] = yb; ac_cap[aid] = CAP[cat_of[tid]]

places = ["Lahore","Karachi","Dubai","Oslo","Denver","Lima","Cairo","Riga","Auckland","Doha","Zurich","Istanbul"]
phases = ['Taxi','Takeoff','Climb','Cruise','Descent','Approach','Landing']
sevs = [s for s,w in [('Minor',45),('Serious',30),('Major',15),('Fatal',10)] for _ in range(w)]
roles = ["Captain","First Officer","Flight Attendant","Flight Engineer"]
wx = ["Clear","Rain","Fog","Snow","Thunderstorm","Crosswind"]

recs_text = ["Review crew rest and scheduling procedures", "Update maintenance inspection intervals",
  "Revise approach and landing checklists", "Retrain crews on windshear and icing procedures",
  "Improve runway safety procedures", "Audit component replacement records"]
responses = ["Procedures revised and crews briefed", "Inspection schedule updated",
  "Training completed for all crews", "Corrective action plan implemented"]
inj_range = {'Minor': (0, 3), 'Serious': (1, 10), 'Major': (5, 30), 'Fatal': (10, 60)}
crew_inj = {'Minor': ['None'], 'Serious': ['None', 'Minor'], 'Major': ['None', 'Minor', 'Serious'], 'Fatal': ['Minor', 'Serious', 'Fatal']}
D = lambda n: dt.timedelta(days=n)

seen = set()
for n in range(150):
    print(f"\rIncident {n+1}/150", end="", flush=True)
    age = random.randint(10, 400) if random.random() < 0.3 else random.randint(40, 3600)   # days since incident
    d = today - D(age)
    ac = ac_ids[n % 5] if n < 3 else random.choice([x for x in ac_ids if ac_year[x] <= d.year])  # aircraft must exist
    sev = random.choice(sevs)
    cap = ac_cap[ac]
    fat = max(1, int(cap * random.random() ** 2)) if sev == 'Fatal' else 0      # never more than the aircraft holds
    inj = min(random.randint(*inj_range[sev]), cap)
    phase = random.choice(phases)
    while (ac, d, phase) in seen:              # same aircraft + day + phase would be the same event
        d += D(1); age -= 1                    # so move this one to the next day
    seen.add((ac, d, phase))
    iid = ins("""INSERT INTO Incident(aircraft_id,incident_date,location,phase_of_flight,severity,fatalities,injuries,description,recorded_by)
                 VALUES(?,?,?,?,?,?,?,?,?)""",
              (ac, d, random.choice(places), phase, sev, fat, inj, "Simulated incident record.", "seed script"))
    cs = [c_ids[0]] if n < 3 else random.sample(c_ids, random.randint(1,3))
    for k, cid in enumerate(cs):
        ex("INSERT INTO Incident_Cause(incident_id,cause_id,is_primary) VALUES(?,?,?)", (iid, cid, 1 if k == 0 else 0))
    ex("INSERT INTO Weather_Condition(incident_id,condition_type,visibility_km,wind_speed_kmh,temperature_c) VALUES(?,?,?,?,?)",
       (iid, random.choice(wx), round(random.uniform(0.5,15),1), random.randint(0,45), random.randint(-15,40)))
    for cr in random.sample(crew_ids, random.randint(2,4)):
        ex("INSERT INTO Incident_Crew VALUES(?,?,?,?)", (iid, cr, random.choice(roles), random.choice(crew_inj[sev])))

    # Realistic investigation timeline: very recent incidents may still be uninvestigated (status Open),
    # recent ones are mostly still under investigation, old ones are finished.
    if age < 90 and random.random() < 0.5:
        continue
    start = min(today, d + D(random.randint(1, 21)))
    end = start + D(random.randint(60, 450))
    finished = age > 600 or (age > 90 and random.random() < 0.4)
    if not finished or end > today:
        end = None
    ex("INSERT INTO Investigation(incident_id,lead_investigator_id,start_date,end_date,probable_cause_summary) VALUES(?,?,?,?,?)",
       (iid, random.choice(inv_ids), start, end, "Final report published." if end else None))

    issue_dates = []
    if end:                                    # recommendations follow the final report
        issue_dates = [min(today, end + D(random.randint(0, 10))) for _ in range(random.randint(1, 2))]
    elif random.random() < 0.15 and start + D(30) <= today:   # occasional interim recommendation
        issue_dates = [min(today, start + D(random.randint(30, 90)))]
    for issued in issue_dates:
        due = issued + D(random.randint(90, 270))
        closed = random.random() < (0.9 if due < today - D(365) else 0.5)
        closed_on = None
        if closed:
            latest = min(today, due + D(30))
            closed_on = min(today, issued + D(random.randint(14, max(14, (latest - issued).days))))
        ex("""INSERT INTO Safety_Recommendation(incident_id,airline_id,rec_text,issued_date,due_date,status,response_text,closed_date)
              VALUES(?,?,?,?,?,?,?,?)""",
           (iid, airline_of[ac], random.choice(recs_text), issued, due, 'Closed' if closed else 'Open',
            random.choice(responses) if closed else None, closed_on))
print()
# ---- login accounts (passwords are stored hashed) ----
H = lambda p: generate_password_hash(p, method="pbkdf2:sha256")
accounts = [("admin", "System Administrator", "Admin123!", "Admin", None),
            ("investigator1", "Lena Berg", "Invest123!", "Investigator", None),
            ("officer1", "Safety Officer", "Officer123!", "Officer", None)]
for (nm, _, _), aid in zip(airlines, a_ids):
    accounts.append((re.sub(r"\W+", "_", nm.lower()), nm + " (airline)", "Airline123!", "Airline", aid))
for u, full, pw, role, aid in accounts:
    ex("INSERT INTO Users(username,full_name,password_hash,role,airline_id) VALUES(?,?,?,?,?)", (u, full, H(pw), role, aid))
c.commit(); cur.close(); c.close()
print("Seeded simulated data.")
