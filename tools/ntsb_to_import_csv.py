"""ntsb_to_import_csv.py - turn an NTSB aviation accident CSV into the BlackBox DB import format (task A3).

Usage:
    python tools/ntsb_to_import_csv.py AviationData.csv data/real_sample.csv --rows 2000

Input : any NTSB-style CSV (column names are matched loosely: 'Event.Date', 'Event Date', 'event_date' all work).
Output: header  date,location,registration,operator,model,phase,fatalities,injuries,weather
        date = YYYY-MM-DD, injuries = serious + minor, model = "Make Model".
It keeps only rows with a valid date (1995 to 2025) and a registration of 12 characters or fewer, drops repeated
(registration, date, phase) rows, and takes a random sample with a fixed seed (same file every time).
"""
import argparse, csv, random, re, sys, datetime as dt

# output column -> accepted input names (lower case, letters and digits only)
ALIASES = {
    "date":         ["eventdate", "date"],
    "location":     ["location"],
    "city":         ["city"], "state": ["state"],
    "registration": ["registrationnumber", "regisno", "registration", "nnumber", "n"],
    "operator":     ["aircarrier", "operator", "opername", "operatorname"],
    "make":         ["make", "acftmake", "manufacturer"],
    "model":        ["model", "acftmodel"],
    "phase":        ["broadphaseofflight", "phaseofflight", "phase"],
    "fatal":        ["totalfatalinjuries", "fatalinjurycount", "fatalities", "injtotf"],
    "serious":      ["totalseriousinjuries", "seriousinjurycount", "injtots"],
    "minor":        ["totalminorinjuries", "minorinjurycount", "injtotm"],
    "weather":      ["weathercondition", "wxcondbasic", "weather"],
}
OUT = ["date", "location", "registration", "operator", "model", "phase", "fatalities", "injuries", "weather"]
DATE_FORMATS = ["%Y-%m-%d", "%m/%d/%Y", "%d-%b-%y", "%d-%b-%Y", "%Y/%m/%d", "%m/%d/%Y %H:%M", "%Y-%m-%d %H:%M:%S"]


def norm(h):
    return re.sub(r"[^a-z0-9]", "", h.lower())


def to_date(text):
    text = (text or "").strip()
    for f in DATE_FORMATS:
        try:
            return dt.datetime.strptime(text, f).date()
        except ValueError:
            pass
    return None


def to_int(text):
    try:
        return max(0, int(round(float((text or "").strip() or 0))))
    except ValueError:
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source"); ap.add_argument("target")
    ap.add_argument("--rows", type=int, default=2000); ap.add_argument("--seed", type=int, default=2026)
    a = ap.parse_args()

    for enc in ("utf-8-sig", "cp1252"):
        try:
            f = open(a.source, newline="", encoding=enc); f.readline(); f.seek(0); break
        except UnicodeDecodeError:
            continue
    rd = csv.DictReader(f)
    names = {norm(h): h for h in (rd.fieldnames or [])}
    col = {k: next((names[x] for x in v if x in names), None) for k, v in ALIASES.items()}
    missing = [k for k in ("date", "registration", "model", "phase", "fatal") if not col[k]]
    if not col["location"] and not col["city"]:
        missing.append("location")
    if missing:
        sys.exit(f"Cannot find columns for: {missing}\nColumns in your file: {rd.fieldnames}")
    print("Column mapping:", {k: v for k, v in col.items() if v})

    seen, good, total = set(), [], 0
    for r in rd:
        total += 1
        d = to_date(r[col["date"]])
        reg = (r[col["registration"]] or "").strip().upper()
        if not d or not (dt.date(1995, 1, 1) <= d <= dt.date(2025, 12, 31)) or not reg or len(reg) > 12:
            continue
        loc = (r[col["location"]] if col["location"] else f"{r[col['city']]}, {r[col['state']] if col['state'] else ''}").strip(" ,")
        make = (r[col["make"]].strip().title() if col["make"] else "")
        model = f"{make} {r[col['model']].strip()}".strip()
        phase = (r[col["phase"]] or "").strip().title()
        key = (reg, d, phase.upper())
        if key in seen:
            continue
        seen.add(key)
        inj = to_int(r[col["serious"]] if col["serious"] else 0) + to_int(r[col["minor"]] if col["minor"] else 0)
        good.append([d.isoformat(), loc, reg, (r[col["operator"]] or "").strip().title() if col["operator"] else "", model,
                     phase, to_int(r[col["fatal"]]), inj, (r[col["weather"]] or "").strip() if col["weather"] else ""])
    random.seed(a.seed)
    pick = sorted(random.sample(good, min(a.rows, len(good))), key=lambda x: x[0])
    with open(a.target, "w", newline="", encoding="utf-8") as out:
        w = csv.writer(out); w.writerow(OUT); w.writerows(pick)
    print(f"Read {total} rows, {len(good)} usable, wrote {len(pick)} rows to {a.target}")


if __name__ == "__main__":
    main()
