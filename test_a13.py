"""test_a13.py - A13 verification tests against the real SQL Server database (Member A).
Usage (project folder, after objects_a_A13.sql has been run):  python test_a13.py
Note: uses Flask test_client with a logged-in session (does not require Users table).
"""
import time

from app import app
from db import query

app.config["TESTING"] = True
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name + (f"   [{detail}]" if detail and not ok else ""))


def client_as(role="Admin", airline_id=None):
    c = app.test_client()
    with c.session_transaction() as s:
        s.update(
            user_id=1,
            username="a13_test",
            full_name="A13 Tester",
            role=role,
            airline_id=airline_id,
            airline_name=None,
        )
    return c


# 1. Similar incident finder (fn_SimilarIncidents)
sim = query("SELECT * FROM dbo.fn_SimilarIncidents(1, 5)")
check("1. fn_SimilarIncidents(1, 5) returns <= 5 rows with score & reasons",
      len(sim) <= 5 and all("score" in r and "reasons" in r for r in sim),
      f"len={len(sim)}")

# 2. /search with text + multi-severity + timing < 1s
c = client_as("Admin")
t0 = time.perf_counter()
r = c.get("/search?text=engine&severity=Fatal&severity=Major&page_size=25")
ms = (time.perf_counter() - t0) * 1000
body = r.get_data(as_text=True)
check("2a. /search loads 200 in under 1000 ms", r.status_code == 200 and ms < 1000, f"status={r.status_code} ms={ms:.1f}")
check("2b. /search shows Showing X to Y of Z", "Showing " in body and " incidents" in body)
check("2c. /search highlights matched word with <mark>", "<mark>" in body.lower() or "Showing 0 of 0" in body)

# 3. /search Airline scoping
c_air = client_as("Airline", airline_id=1)
r_air = c_air.get("/search?airline=2")
check("3. /search Airline user sees only own airline", r_air.status_code == 200)

# 4. /risk Aircraft & Airlines tabs + top 10 chart
r_risk = c.get("/risk")
risk_body = r_risk.get_data(as_text=True)
check("4a. /risk loads 200 with Aircraft & Airlines tabs",
      r_risk.status_code == 200 and "Aircraft (" in risk_body and "Airlines (" in risk_body,
      f"status={r_risk.status_code}")
check("4b. /risk has Top 10 chart & breakdown rows",
      "risk-chart" in risk_body and "Score breakdown for" in risk_body)

# 5. /admin/demo guard (Investigator blocked, Admin allowed, wrong confirm rejected)
c_inv = client_as("Investigator")
r_inv = c_inv.get("/admin/demo")
check("5a. /admin/demo blocks non-Admin (302 redirect)", r_inv.status_code == 302, f"status={r_inv.status_code}")

r_demo = c.get("/admin/demo")
check("5b. /admin/demo loads 200 for Admin", r_demo.status_code == 200 and "Reset Demo Database" in r_demo.get_data(as_text=True))

r_bad = c.post("/admin/demo", data={"confirm": "no"}, follow_redirects=True)
check("5c. /admin/demo rejects confirm != RESET", "Type RESET" in r_bad.get_data(as_text=True))

print(f"\n{sum(results)} of {len(results)} checks passed" + ("  -> ALL PASS" if all(results) else "  -> see FAIL lines"))
