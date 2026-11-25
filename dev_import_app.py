"""dev_import_app.py - runs ONLY the /import page, with no login, for testing before Member B's tables exist.
Needs just the incident-side database (00_create_db.sql, schema_incident.sql, seed_a.py, objects_a.sql).
    python dev_import_app.py      then open http://127.0.0.1:5000
Not part of the final app: once schema_people.sql is merged, run `python app.py` instead.
"""
from flask import Flask, session, redirect, render_template_string
from db import query
import import_routes

app = Flask(__name__)
app.secret_key = "dev-only"


@app.before_request
def fake_login():                      # pretend an Admin is logged in
    session.update(user_id=0, username="dev_admin", role="Admin", full_name="Dev user (Member A)",
                   airline_id=None, airline_name=None)


@app.context_processor
def inject_user():                     # the same names base.html expects from app.py
    return dict(role="Admin", full_name="Dev user (Member A)", airline_name=None, can_edit=False, can_close=False)


@app.route("/")
def home():
    return redirect("/import")


@app.route("/incidents")
def incidents():
    rows = query("""SELECT TOP 100 i.incident_id, i.incident_date, a.registration_no, i.location, i.phase_of_flight,
                    i.severity, i.fatalities, i.injuries, i.status, i.description
                    FROM Incident i JOIN Aircraft a ON a.aircraft_id = i.aircraft_id ORDER BY i.incident_id DESC""")
    return render_template_string("""{% extends "base.html" %}{% block body %}
      <h3>Incidents <small class="text-secondary fs-6">(test view: newest 100)</small></h3>
      <div class="table-responsive"><table class="table table-sm"><thead><tr>{% for k in rows[0].keys() %}<th>{{ k }}</th>{% endfor %}</tr></thead>
      <tbody>{% for r in rows %}<tr>{% for v in r.values() %}<td>{{ v }}</td>{% endfor %}</tr>{% endfor %}</tbody></table></div>
      {% endblock %}""", rows=rows)


@app.route("/audit")
def audit():
    rows = query("SELECT TOP 50 * FROM Audit_Log ORDER BY log_id DESC")
    return render_template_string("""{% extends "base.html" %}{% block body %}
      <h3>Audit log <small class="text-secondary fs-6">(test view)</small></h3>
      <div class="table-responsive"><table class="table table-sm"><thead><tr>{% for k in rows[0].keys() %}<th>{{ k }}</th>{% endfor %}</tr></thead>
      <tbody>{% for r in rows %}<tr>{% for v in r.values() %}<td>{{ v }}</td>{% endfor %}</tr>{% endfor %}</tbody></table></div>
      {% endblock %}""", rows=rows)


import_routes.register(app, {})

if __name__ == "__main__":
    app.run(debug=True)
