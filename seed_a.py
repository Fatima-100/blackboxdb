"""seed_a.py - Member A seed script (task A2).

Loads SIMULATED data for the incident side: 62 airports, 12 airlines, 25 aircraft types, 120 aircraft,
maintenance records, about 6,000 flights and 10,000 incidents (1995-2025) with causes, weather and crew.

Run once on an EMPTY database (after 00_create_db.sql and schema_incident.sql):
    python seed_a.py              load the data
    python seed_a.py --dry-run    generate the data in memory and check every rule, no database needed

Same data on every run: random.seed(2026). The first 150 incidents are the fixed demo set
(incident_id 1 to 150 on a fresh database).  Member B's seed_b.py reads Incident.status to decide
which incidents get an investigation (Closed -> finished, Under Investigation -> running, Open -> none).
"""
import csv, os, random, sys, time, datetime as dt
from decimal import Decimal

random.seed(2026)                      # keep at the top: the same data on every run

HERE = os.path.dirname(os.path.abspath(__file__))
SEED = 2026
N_INCIDENTS = 10000
N_DEMO = 150                           # first 150 incidents = fixed demo set
N_AIRCRAFT = 120
N_CREW = 200
LINK_RATE = 0.60                       # share of incidents linked to a flight and an airport
BATCH = 1000                           # commit every 1,000 rows
FIRST_DATE, LAST_DATE = dt.date(1995, 1, 1), dt.date(2025, 12, 31)
STATUS_REF = dt.date(2026, 1, 1)       # fixed date used to decide Open / Under Investigation / Closed

D = lambda n: dt.timedelta(days=n)

# ----------------------------------------------------------------------------- lookup data
AIRLINES = [("Skyline Air", "Pakistan", "SK"), ("Meridian Airways", "UAE", "MD"), ("Nordic Wings", "Norway", "NW"),
            ("Pacific Crest", "USA", "PC"), ("Andes Connect", "Peru", "AC"), ("Sahara Jet", "Egypt", "SJ"),
            ("Baltic Air", "Latvia", "BA"), ("Kiwi Regional", "New Zealand", "KR"), ("Gulf Horizon", "Qatar", "GH"),
            ("Alpine Air", "Switzerland", "AL"), ("Steppe Wings", "Kazakhstan", "SW"), ("Monsoon Air", "India", "MN")]

TYPES = [("Boeing", "737-800", "Narrow-body"), ("Boeing", "737 MAX 8", "Narrow-body"), ("Airbus", "A320-200", "Narrow-body"),
         ("Airbus", "A321neo", "Narrow-body"), ("Boeing", "757-200", "Narrow-body"), ("McDonnell Douglas", "MD-82", "Narrow-body"),
         ("Boeing", "777-300ER", "Wide-body"), ("Boeing", "787-9", "Wide-body"), ("Airbus", "A330-300", "Wide-body"),
         ("Airbus", "A350-900", "Wide-body"), ("Boeing", "747-400", "Wide-body"),
         ("Embraer", "E175", "Regional jet"), ("Embraer", "E190", "Regional jet"), ("Bombardier", "CRJ900", "Regional jet"),
         ("Bombardier", "CRJ200", "Regional jet"),
         ("ATR", "72-600", "Turboprop"), ("ATR", "42-500", "Turboprop"), ("De Havilland", "Dash 8 Q400", "Turboprop"),
         ("Saab", "340B", "Turboprop"), ("Fokker", "50", "Turboprop"),
         ("Cessna", "172", "Light"), ("Cessna", "208 Caravan", "Light"), ("Beechcraft", "King Air 350", "Light"),
         ("Piper", "PA-34 Seneca", "Light"), ("Pilatus", "PC-12", "Light")]

CAUSES = [("Engine failure", "Mechanical"), ("Hydraulic failure", "Mechanical"), ("Landing gear malfunction", "Mechanical"),
          ("Electrical fault", "Mechanical"), ("Pilot error", "Human factors"), ("Crew fatigue", "Human factors"),
          ("Miscommunication with ATC", "Human factors"), ("Bird strike", "Environmental"), ("Windshear", "Weather"),
          ("Icing", "Weather"), ("Low visibility", "Weather"), ("Wake turbulence", "Weather"),
          ("Runway incursion", "Operational"), ("Runway excursion", "Operational"), ("Maintenance error", "Maintenance"),
          ("Fuel contamination", "Maintenance")]

CAP = {"Light": 4, "Turboprop": 78, "Regional jet": 88, "Narrow-body": 190, "Wide-body": 400}   # passengers + crew limit
PHASES = ["Taxi", "Takeoff", "Climb", "Cruise", "Descent", "Approach", "Landing"]
SEVERITIES = ["Minor", "Serious", "Major", "Fatal"]
SEV_WEIGHTS = [45, 30, 15, 10]                      # same weights as the old seed
INJ_RANGE = {"Minor": (0, 3), "Serious": (1, 10), "Major": (5, 30), "Fatal": (10, 60)}
CREW_INJ = {"Minor": ["None"], "Serious": ["None", "Minor"], "Major": ["None", "Minor", "Serious"],
            "Fatal": ["Minor", "Serious", "Fatal"]}
ROLES = ["Captain", "First Officer", "Flight Attendant", "Flight Attendant", "Flight Engineer"]
WEATHER = ["Clear", "Rain", "Fog", "Snow", "Thunderstorm", "Crosswind"]
WEATHER_FOR_CAUSE = {"Icing": "Snow", "Low visibility": "Fog", "Windshear": "Thunderstorm"}
MAINT_TYPES = ["Routine"] * 50 + ["Inspection"] * 25 + ["Repair"] * 15 + ["Heavy"] * 10
MAINT_NOTES = [None, "Scheduled check completed", "Parts replaced and tested", "Findings corrected, aircraft released",
               "Deferred item cleared"]
FIRST = ["Amna", "David", "Sofia", "Hamza", "Lena", "Tariq", "Omar", "Elena", "Jonas", "Priya", "Chen", "Maria", "Ali",
         "Noor", "Liam", "Aisha", "Mateo", "Ingrid", "Yusuf", "Hana", "Pedro", "Zara", "Ivan", "Mei", "Samuel"]
LAST = ["Rauf", "Clarke", "Marin", "Qureshi", "Berg", "Aziz", "Haddad", "Petrov", "Larsen", "Sharma", "Wei", "Santos",
        "Khan", "Hussain", "Murphy", "Farouk", "Silva", "Nielsen", "Demir", "Sato", "Rojas", "Malik", "Volkov", "Lin", "Okafor"]

# 6 fixed demo incidents (incident_id 1 to 6). Aircraft index 0 to 4 are built 1985-1994, so any date is valid.
FORCED = [  # (aircraft idx, date, phase, severity, linked to flight, primary cause name)
    (0, dt.date(2016, 3, 14), "Takeoff", "Fatal", True, "Engine failure"),
    (0, dt.date(2025, 9, 2), "Approach", "Serious", True, "Engine failure"),
    (0, dt.date(2008, 11, 20), "Taxi", "Minor", False, "Engine failure"),
    (1, dt.date(2021, 6, 9), "Landing", "Major", True, "Pilot error"),
    (2, dt.date(2019, 1, 27), "Approach", "Fatal", True, "Windshear"),
    (3, dt.date(2024, 5, 18), "Climb", "Minor", False, "Bird strike"),
]


def load_airports():
    with open(os.path.join(HERE, "data", "airports.csv"), newline="", encoding="utf-8") as f:
        return [(r["iata_code"], r["icao_code"], r["name"], r["city"], r["country"],
                 Decimal(r["latitude"]), Decimal(r["longitude"])) for r in csv.DictReader(f)]


def pick_status(d):
    """Incident status by age (fixed reference date, so the result never changes between runs)."""
    age = (STATUS_REF - d).days
    w = [20, 60, 20] if age <= 180 else ([0, 15, 85] if age <= 730 else [0, 2, 98])
    return random.choices(["Open", "Under Investigation", "Closed"], weights=w)[0]


def pax_for(cap):
    return random.randint(max(1, int(cap * 0.3)), max(1, int(cap * 0.95)))


# ----------------------------------------------------------------------------- generate everything in memory
def generate(ac_cat=None, cause_cat=None):
    """Return all rows as tuples. Foreign keys are stored as 0-based positions (index in the parent list);
    run() replaces them with the real identity values after the parent rows are inserted."""
    random.seed(SEED)
    ac_cat = ac_cat or {n: i + 1 for i, n in enumerate(CAP)}
    cause_cat = cause_cat or {n: i + 1 for i, n in enumerate(sorted({c[1] for c in CAUSES}))}
    airports = load_airports()
    today = dt.date.today()
    out = {}

    out["Airport"] = airports
    out["Airline"] = [(n, c, i) for n, c, i in AIRLINES]
    out["Aircraft_Type"] = [(m, mo, ac_cat[cat]) for m, mo, cat in TYPES]
    out["Cause"] = [(n, cause_cat[c]) for n, c in CAUSES]
    out["Crew_Member"] = [(f"{random.choice(FIRST)} {random.choice(LAST)}", random.choice(ROLES), f"LIC-{1001 + i}",
                           random.randint(1, 30)) for i in range(N_CREW)]

    # ---- aircraft: the first 5 belong to airline 0 and are old enough for any demo date
    ac_year, ac_cap, ac_airline, aircraft = [], [], [], []
    for i in range(N_AIRCRAFT):
        al = 0 if i < 5 else random.randrange(len(AIRLINES))
        tp = random.randrange(len(TYPES))
        yb = random.randint(1985, 1994) if i < 5 else random.randint(1985, 2022)
        st = "Active" if i < 5 else random.choices(["Active", "Grounded", "Retired"], weights=[88, 8, 4])[0]
        aircraft.append((f"AP-{100 + i}", al, tp, yb, st))
        ac_year.append(yb); ac_cap.append(CAP[TYPES[tp][2]]); ac_airline.append(al)
    out["Aircraft"] = aircraft

    # ---- maintenance: 3 to 6 per aircraft, about 30% of aircraft have the latest due date in the past
    maint = []
    for a in range(N_AIRCRAFT):
        n = random.randint(3, 6)
        overdue = random.random() < 0.30
        if overdue:
            last = today - D(random.randint(400, 900)); due_last = last + D(random.randint(90, 300))
        else:
            last = today - D(random.randint(10, 200)); due_last = today + D(random.randint(15, 250))
        build_start = dt.date(ac_year[a], 1, 1)
        last = max(last, build_start)
        step = max(5, min(250, (last - build_start).days // n))
        dates = [last]
        for _ in range(n - 1):
            dates.append(dates[-1] - D(random.randint(max(3, step // 2), step)))
        dates.reverse()
        for k, md in enumerate(dates):
            due = due_last if k == n - 1 else md + D(random.randint(60, 365))
            maint.append((a, md, random.choice(MAINT_TYPES), random.choice(MAINT_NOTES), due))
    out["Maintenance_Record"] = maint

    # ---- incidents
    cause_idx = {n: i for i, (n, _) in enumerate(CAUSES)}
    span = (LAST_DATE - FIRST_DATE).days
    by_year = {y: [i for i in range(N_AIRCRAFT) if ac_year[i] <= y] for y in range(FIRST_DATE.year, LAST_DATE.year + 1)}
    seen, raw = set(), []
    for n in range(N_INCIDENTS):
        if n < len(FORCED):
            a, d, phase, sev, linked, pc = FORCED[n]
            primary = cause_idx[pc]
        else:
            while True:                                         # new event = new (aircraft, date, phase)
                d = FIRST_DATE + D(random.randint(0, span))
                a = random.choice(by_year[d.year])             # aircraft must already be built
                phase = random.choice(PHASES)
                if (a, d, phase) not in seen:
                    break
            sev = random.choices(SEVERITIES, weights=SEV_WEIGHTS)[0]
            linked = random.random() < LINK_RATE
            primary = random.randrange(len(CAUSES))
        assert (a, d, phase) not in seen
        seen.add((a, d, phase))
        others = random.sample([c for c in range(len(CAUSES)) if c != primary], random.randint(0, 2))
        causes = [primary] + others                             # first one is the primary cause
        cap = ac_cap[a]
        pax = pax_for(cap)
        fat = max(1, int(pax * random.random() ** 2)) if sev == "Fatal" else 0
        inj = min(random.randint(*INJ_RANGE[sev]), cap)
        crew = random.sample(range(N_CREW), random.randint(2, 4))
        raw.append(dict(a=a, d=d, phase=phase, sev=sev, linked=linked, causes=causes, pax=pax, fat=fat, inj=inj,
                        status=pick_status(d), crew=crew, wx=WEATHER_FOR_CAUSE.get(CAUSES[primary][0], random.choice(WEATHER)),
                        vis=round(random.uniform(0.5, 15), 1), wind=random.randint(0, 45), temp=random.randint(-15, 40),
                        crew_rows=[(c, random.choice(ROLES), random.choice(CREW_INJ[sev])) for c in crew]))
    raw = raw[:N_DEMO] + sorted(raw[N_DEMO:], key=lambda r: (r["d"], r["a"]))   # demo set first, then by date

    flights, incidents, weather, inc_cause, inc_crew = [], [], [], [], []
    for i, r in enumerate(raw):
        flight_idx = airport_idx = None
        if r["linked"]:
            o, de = random.sample(range(len(airports)), 2)
            flights.append((f"{AIRLINES[ac_airline[r['a']]][2]}{random.randint(100, 9999)}", ac_airline[r["a"]], r["a"],
                            o, de, r["d"], r["pax"]))
            flight_idx = len(flights) - 1
            airport_idx = o if r["phase"] in ("Taxi", "Takeoff", "Climb") else (
                de if r["phase"] in ("Descent", "Approach", "Landing") else random.choice([o, de]))
            location = f"{airports[airport_idx][3]}, {airports[airport_idx][4]}"
        else:
            ap = random.choice(airports)
            location = f"Near {ap[3]}, {ap[4]}"
        pc_name = CAUSES[r["causes"][0]][0].lower()
        incidents.append((r["a"], airport_idx, flight_idx, r["d"], location, r["phase"], r["sev"], r["fat"], r["inj"],
                          r["pax"], r["status"], f"Simulated incident: {pc_name} during {r['phase'].lower()}.",
                          "seed script"))
        weather.append((i, r["wx"], r["vis"], r["wind"], r["temp"]))
        for k, c in enumerate(r["causes"]):
            inc_cause.append((i, c, 1 if k == 0 else 0))
        for c, role, injs in r["crew_rows"]:
            inc_crew.append((i, c, role, injs))
    out["Flight"] = flights
    out["Incident"] = incidents
    out["Weather_Condition"] = weather
    out["Incident_Cause"] = inc_cause
    out["Incident_Crew"] = inc_crew
    return out


# ----------------------------------------------------------------------------- the same rules the schema enforces
def self_check(data):
    """Raise AssertionError if any generated row would break a CHECK, UNIQUE, trigger or foreign-key rule."""
    today = dt.date.today()
    ap, al, ac, fl, inc = data["Airport"], data["Airline"], data["Aircraft"], data["Flight"], data["Incident"]
    assert len({a[0] for a in ap}) == len(ap) and len({a[1] for a in ap}) == len(ap), "duplicate airport code"
    assert all(-90 <= a[5] <= 90 and -180 <= a[6] <= 180 and len(a[0]) == 3 and len(a[1]) == 4 for a in ap)
    assert len({a[2] for a in al}) == len(al) and len({a[0] for a in al}) == len(al)
    assert len({a[0] for a in ac}) == len(ac) and all(1930 <= a[3] <= 2100 for a in ac)
    assert len({c[2] for c in data["Crew_Member"]}) == len(data["Crew_Member"])
    for _, md, mt, _, due in data["Maintenance_Record"]:
        assert md <= today and due >= md and mt in ("Routine", "Inspection", "Repair", "Heavy")
    for f in fl:
        assert f[3] != f[4] and f[6] >= 0
    events, used_flights, incident_flights = set(), set(), []
    for i, r in enumerate(inc):
        a, apt, fidx, d, loc, ph, sev, fat, injs, pax, st = r[:11]
        assert d <= today and d <= LAST_DATE and d.year >= ac[a][3], f"bad date on incident {i}"
        assert (a, d, ph) not in events, "duplicate event"; events.add((a, d, ph))
        assert ph in PHASES and sev in SEVERITIES and fat >= 0 and injs >= 0 and pax >= 1
        assert st in ("Open", "Under Investigation", "Closed")
        assert (sev == "Fatal") == (fat >= 1) and fat <= pax
        assert (apt is None) == (fidx is None)
        if fidx is not None:
            assert fidx not in used_flights; used_flights.add(fidx)
            assert fl[fidx][2] == a and fl[fidx][5] == d, "flight does not match incident"
    primaries, cnt = {}, {}
    for i, c, p in data["Incident_Cause"]:
        cnt[i] = cnt.get(i, 0) + 1; primaries[i] = primaries.get(i, 0) + p
    assert len(cnt) == len(inc) and all(1 <= v <= 3 for v in cnt.values()) and all(v == 1 for v in primaries.values())
    assert len({(i, c) for i, c, _ in data["Incident_Cause"]}) == len(data["Incident_Cause"])
    crew_cnt = {}
    for i, c, role, injs in data["Incident_Crew"]:
        crew_cnt[i] = crew_cnt.get(i, 0) + 1
    assert len(crew_cnt) == len(inc) and all(2 <= v <= 4 for v in crew_cnt.values())
    assert len({(i, c) for i, c, _, _ in data["Incident_Crew"]}) == len(data["Incident_Crew"])
    assert len(data["Weather_Condition"]) == len(inc)


def summary(data):
    inc = data["Incident"]
    sev = {s: sum(1 for r in inc if r[6] == s) for s in SEVERITIES}
    st = {s: sum(1 for r in inc if r[10] == s) for s in ("Open", "Under Investigation", "Closed")}
    print("Rows to load:", {t: len(v) for t, v in data.items()})
    print("Severity:", {k: f"{v * 100 / len(inc):.1f}%" for k, v in sev.items()})
    print("Status:", st, "| linked to flight+airport:", f"{len(data['Flight']) * 100 / len(inc):.1f}%")
    print("Date range:", min(r[3] for r in inc), "to", max(r[3] for r in inc))
    od = {}
    for a, md, _, _, due in data["Maintenance_Record"]:
        od[a] = max(od.get(a, dt.date.min), due)
    print("Aircraft with latest maintenance due date in the past:", sum(1 for v in od.values() if v < dt.date.today()))


# ----------------------------------------------------------------------------- database load
LOAD_TABLES = ["Airline", "Aircraft_Type", "Cause", "Crew_Member", "Airport", "Aircraft", "Flight", "Maintenance_Record",
               "Incident", "Weather_Condition", "Incident_Cause", "Incident_Crew"]
ID_COL = {"Airline": "airline_id", "Aircraft_Type": "type_id", "Cause": "cause_id", "Crew_Member": "crew_id",
          "Airport": "airport_id", "Aircraft": "aircraft_id", "Flight": "flight_id", "Incident": "incident_id"}
SQL = {
    "Airline": "INSERT INTO Airline(name,country,iata_code) VALUES(?,?,?)",
    "Aircraft_Type": "INSERT INTO Aircraft_Type(manufacturer,model,category_id) VALUES(?,?,?)",
    "Cause": "INSERT INTO Cause(cause_name,category_id) VALUES(?,?)",
    "Crew_Member": "INSERT INTO Crew_Member(name,role,license_no,experience_years) VALUES(?,?,?,?)",
    "Airport": "INSERT INTO Airport(iata_code,icao_code,name,city,country,latitude,longitude) VALUES(?,?,?,?,?,?,?)",
    "Aircraft": "INSERT INTO Aircraft(registration_no,airline_id,type_id,year_built,status) VALUES(?,?,?,?,?)",
    "Flight": "INSERT INTO Flight(flight_no,airline_id,aircraft_id,origin_airport_id,dest_airport_id,flight_date,passengers_on_board) VALUES(?,?,?,?,?,?,?)",
    "Maintenance_Record": "INSERT INTO Maintenance_Record(aircraft_id,maint_date,maint_type,notes,next_due_date) VALUES(?,?,?,?,?)",
    "Incident": "INSERT INTO Incident(aircraft_id,airport_id,flight_id,incident_date,location,phase_of_flight,severity,fatalities,injuries,passengers_on_board,status,description,recorded_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
    "Weather_Condition": "INSERT INTO Weather_Condition(incident_id,condition_type,visibility_km,wind_speed_kmh,temperature_c) VALUES(?,?,?,?,?)",
    "Incident_Cause": "INSERT INTO Incident_Cause(incident_id,cause_id,is_primary) VALUES(?,?,?)",
    "Incident_Crew": "INSERT INTO Incident_Crew(incident_id,crew_id,role_on_flight,injury_status) VALUES(?,?,?,?)",
}


def remap(rows, spec):
    """Replace 0-based positions with real identity values. spec = {column position: list of real ids}."""
    out = []
    for r in rows:
        r = list(r)
        for pos, ids in spec.items():
            if r[pos] is not None:
                r[pos] = ids[r[pos]]
        out.append(tuple(r))
    return out


def run():
    from db import conn
    t0 = time.time()
    c = conn(); cur = c.cursor()
    cur.execute("EXEC sp_set_session_context @key = N'app_user', @value = N'seed script'")

    # ---- the database must be empty (otherwise unique rules and the fixed demo IDs would break)
    for t in LOAD_TABLES:
        n = cur.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        if n:
            sys.exit(f"STOP: table {t} already has {n} rows. Run 00_create_db.sql and schema_incident.sql again, then seed.")

    ac_cat = {r[1]: r[0] for r in cur.execute("SELECT category_id, category_name FROM Aircraft_Category").fetchall()}
    cause_cat = {r[1]: r[0] for r in cur.execute("SELECT category_id, category_name FROM Cause_Category").fetchall()}
    data = generate(ac_cat, cause_cat)
    self_check(data)
    print("Generated and checked in memory:", {t: len(v) for t, v in data.items()})

    try:
        cur.fast_executemany = os.environ.get("FAST_EXECUTEMANY", "1") != "0"
    except AttributeError:
        pass
    ids = {}

    def load(table, rows):
        for i in range(0, len(rows), BATCH):
            cur.executemany(SQL[table], rows[i:i + BATCH])
            c.commit()
        if table in ID_COL:
            ids[table] = [r[0] for r in cur.execute(f"SELECT {ID_COL[table]} FROM {table} ORDER BY {ID_COL[table]}").fetchall()]
            assert len(ids[table]) == len(rows), f"{table}: expected {len(rows)} ids, got {len(ids[table])}"
        print(f"  {table:<20} {len(rows):>7} rows")

    # Triggers off for the bulk load (they would fire 10,000 times); the script sets every status itself and
    # self_check() above applies the same rules the triggers apply. They are switched on again in the finally block.
    for t in LOAD_TABLES:
        cur.execute(f"ALTER TABLE {t} DISABLE TRIGGER ALL")
    c.commit()
    try:
        load("Airline", data["Airline"])
        load("Aircraft_Type", data["Aircraft_Type"])
        load("Cause", data["Cause"])
        load("Crew_Member", data["Crew_Member"])
        load("Airport", data["Airport"])
        load("Aircraft", remap(data["Aircraft"], {1: ids["Airline"], 2: ids["Aircraft_Type"]}))
        load("Flight", remap(data["Flight"], {1: ids["Airline"], 2: ids["Aircraft"], 3: ids["Airport"], 4: ids["Airport"]}))
        load("Maintenance_Record", remap(data["Maintenance_Record"], {0: ids["Aircraft"]}))
        load("Incident", remap(data["Incident"], {0: ids["Aircraft"], 1: ids["Airport"], 2: ids["Flight"]}))
        # make sure row N of the list really became identity N (the children depend on it)
        for pos in (0, N_DEMO - 1, len(ids["Incident"]) - 1):
            got = cur.execute("SELECT aircraft_id, incident_date, phase_of_flight FROM Incident WHERE incident_id = ?",
                              ids["Incident"][pos]).fetchone()
            exp = data["Incident"][pos]
            assert (got[0], got[1], got[2]) == (ids["Aircraft"][exp[0]], exp[3], exp[5]), "incident order mismatch"
        load("Weather_Condition", remap(data["Weather_Condition"], {0: ids["Incident"]}))
        load("Incident_Cause", remap(data["Incident_Cause"], {0: ids["Incident"], 1: ids["Cause"]}))
        load("Incident_Crew", remap(data["Incident_Crew"], {0: ids["Incident"], 1: ids["Crew_Member"]}))
    except Exception:
        c.rollback()
        print("\nLoad failed. Fix the problem, then run 00_create_db.sql and schema_incident.sql again before re-seeding.")
        raise
    finally:
        for t in LOAD_TABLES:
            cur.execute(f"ALTER TABLE {t} ENABLE TRIGGER ALL")
        c.commit()

    # ---- consistency checks (what the triggers would have checked)
    checks = {
        "incident date in the future": "SELECT COUNT(*) FROM Incident WHERE incident_date > CAST(GETDATE() AS DATE)",
        "incident before aircraft was built": "SELECT COUNT(*) FROM Incident i JOIN Aircraft a ON a.aircraft_id=i.aircraft_id WHERE YEAR(i.incident_date) < a.year_built",
        "incident without exactly one primary cause": "SELECT COUNT(*) FROM Incident i WHERE (SELECT COUNT(*) FROM Incident_Cause c WHERE c.incident_id=i.incident_id AND c.is_primary=1) <> 1",
        "incident without weather": "SELECT COUNT(*) FROM Incident i WHERE NOT EXISTS (SELECT 1 FROM Weather_Condition w WHERE w.incident_id=i.incident_id)",
        "airport without coordinates": "SELECT COUNT(*) FROM Airport WHERE latitude IS NULL OR longitude IS NULL",
    }
    bad = {k: cur.execute(q).fetchone()[0] for k, q in checks.items()}
    if any(bad.values()):
        sys.exit(f"CHECK FAILED: {bad}")
    print("Consistency checks passed (0 violations).")

    print("\nFinal row counts:")
    for t in LOAD_TABLES:
        print(f"  {t:<20} {cur.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0]:>7}")
    first = cur.execute("SELECT MIN(incident_id), MAX(incident_id) FROM Incident").fetchone()
    if first[0] != 1:
        print(f"WARNING: Incident IDs start at {first[0]}, not 1. For the standard demo IDs (1-150) recreate the "
              "database with 00_create_db.sql and schema_incident.sql, then seed again.")
    print(f"Demo set = incident_id {first[0]} to {first[0] + N_DEMO - 1}. Seed A finished in {time.time() - t0:.1f} seconds.")
    cur.close(); c.close()


if __name__ == "__main__":
    if "--dry-run" in sys.argv:
        t = time.time()
        d = generate()
        self_check(d)
        summary(d)
        print(f"Dry run OK in {time.time() - t:.1f} s. Nothing was written to the database.")
    else:
        run()
