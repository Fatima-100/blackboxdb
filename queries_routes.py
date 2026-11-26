"""queries_routes.py - A9: the /queries page (Query Library).

Wire it into app.py with two lines (same pattern as import_routes):
    import queries_routes
    queries_routes.register(app, PERMS)
Only IDs from the fixed list in queries_a.py can run; users never type SQL.
"""
import time
from flask import render_template, request, flash
from db import query
from queries_a import QUERIES, BY_ID

MAX_ROWS = 200
STAFF = ("Admin", "Investigator", "Officer")


def _cell(v):
    return "" if v is None else str(v)


def queries():
    qid = request.args.get("id", "").strip().upper()
    tag = request.args.get("tag", "").strip()
    shown = [q for q in QUERIES if not tag or tag.lower() in q["clause"].lower()]
    selected, columns, rows, total, ms, error = None, [], [], 0, None, None
    if qid:
        selected = BY_ID.get(qid)          # unknown id -> None, nothing runs
        if selected is None:
            flash("Unknown query", "danger")
        else:
            try:
                t0 = time.perf_counter()
                data = query(selected["sql"])
                ms = round((time.perf_counter() - t0) * 1000)
                total = len(data)
                columns = list(data[0].keys()) if data else []
                rows = [[_cell(r[c]) for c in columns] for r in data[:MAX_ROWS]]
            except Exception as e:          # the page must never crash
                error = str(e)[:300]
    return render_template("queries.html", queries=shown, tag=tag, selected=selected,
                           columns=columns, rows=rows, total=total, ms=ms,
                           error=error, max_rows=MAX_ROWS)


def register(app, perms):
    perms["queries"] = STAFF
    app.add_url_rule("/queries", "queries", queries)
