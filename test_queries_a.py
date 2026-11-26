"""test_queries_a.py - runs all 23 queries on ONE connection and checks each takes under 2 seconds.
Only the SQL run + fetch is timed. If a query takes more than 2 seconds, a second
connection looks at what that session is waiting for (wait type, blocker) and prints it,
so a slow query can be explained instead of guessed.
Usage (project folder, database running):  python test_queries_a.py"""
import threading
import time
from db import conn
from queries_a import QUERIES

WATCH_SQL = """SELECT r.status, r.command, r.wait_type, r.wait_time, r.blocking_session_id,
       r.cpu_time, r.logical_reads, r.total_elapsed_time
  FROM sys.dm_exec_requests r WHERE r.session_id = {spid}"""
BLOCKER_SQL = """SELECT s.session_id, s.login_name, s.program_name, s.status, s.open_transaction_count,
       s.host_name, t.text AS last_sql
  FROM sys.dm_exec_sessions s
  LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
  OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
 WHERE s.session_id = {spid}"""


def watch(spid, stop, notes):
    """Runs on its own connection; after 2 s of waiting it records what the session is doing."""
    try:
        c = conn(); cur = c.cursor()
        t0 = time.perf_counter()
        seen = set()
        while not stop.wait(1.0):
            if time.perf_counter() - t0 < 2:
                continue
            cur.execute(WATCH_SQL.format(spid=spid))
            r = cur.fetchone()
            if not r:
                continue
            key = (r.wait_type, r.blocking_session_id)
            if key in seen:
                continue
            seen.add(key)
            line = (f"      waiting: status={r.status} wait_type={r.wait_type} wait_ms={r.wait_time} "
                    f"blocked_by={r.blocking_session_id} cpu_ms={r.cpu_time} reads={r.logical_reads}")
            notes.append(line)
            if r.blocking_session_id:
                cur.execute(BLOCKER_SQL.format(spid=int(r.blocking_session_id)))
                b = cur.fetchone()
                if b:
                    notes.append(f"      blocker: session {b.session_id} login={b.login_name} app={b.program_name} "
                                 f"status={b.status} open_tran={b.open_transaction_count} host={b.host_name}")
                    notes.append(f"      blocker last SQL: {(b.last_sql or '')[:160]!r}")
        cur.close(); c.close()
    except Exception as e:
        notes.append(f"      (watcher could not read the server state: {str(e)[:120]})")


t0 = time.perf_counter()
c = conn()
print(f"connect: {round((time.perf_counter() - t0) * 1000)} ms")
cur = c.cursor()
cur.execute("SELECT @@SPID"); spid = cur.fetchone()[0]
cur.execute("SELECT @@VERSION"); print(cur.fetchone()[0].split("\n")[0], "\n")

bad = 0
for q in QUERIES:
    stop, notes = threading.Event(), []
    w = threading.Thread(target=watch, args=(spid, stop, notes), daemon=True)
    w.start()
    try:
        t0 = time.perf_counter()
        cur.execute(q["sql"])
        rows = cur.fetchall()
        ms = round((time.perf_counter() - t0) * 1000)
        ok = ms < 2000 and len(rows) > 0
        print(f"{q['id']:4} {'PASS' if ok else 'FAIL'}  {ms:5} ms  {len(rows):6} rows  {q['clause']}")
        bad += 0 if ok else 1
    except Exception as e:
        print(f"{q['id']:4} FAIL  error: {str(e)[:150]}")
        bad += 1
    finally:
        stop.set(); w.join(timeout=5)
    for n in notes:
        print(n)
cur.close(); c.close()
print("\nALL 23 PASS" if bad == 0 else f"\n{bad} query(ies) need attention")