"""seed.py - loads all simulated data. Run once, after schema.sql (or after 00_create_db.sql + schema_incident.sql):
    python seed.py
Runs Member A's seed_a.py, then Member B's seed_b.py when it exists (B's file must define run())."""
import seed_a

seed_a.run()
try:
    import seed_b
except ModuleNotFoundError as e:
    if e.name != "seed_b":
        raise
    print("seed_b.py not found yet - only Member A's data was loaded.")
else:
    seed_b.run()
