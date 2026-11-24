# Team workflow

## Branches
- `main`: always runs from zero. Only changed on merge days.
- `member-a`: Member A's work.
- `member-b`: Member B's work.

Daily routine: `git pull` before you start, small commits while you work, `git push` at the end of the day.

## Merge days (merge into main only after both run the whole project from zero)
| Day | What |
|-----|------|
| D3  | Schema merge: both schema files run with no error, cross-file foreign keys work |
| (see task book for the rest) | |

Merge steps:
```
git checkout main && git pull
git merge member-a
git merge member-b
# run: schema.sql, seed.py, the app, demo.sql
git push
git checkout member-a && git merge main     # bring both branches up to date
git checkout member-b && git merge main
```
Tag at D25: `git tag v1.0-rc`.

## File ownership (nobody edits the other person's file; message them the change you need)
| Member A | Member B |
|---|---|
| `00_create_db.sql`, `schema_incident.sql`, `objects_a.sql`, `seed_a.py`, `demo_a.sql` | `schema_people.sql`, `objects_b.sql`, `seed_b.py`, `demo_b.sql` |
| incident-side pages and templates | `docs/` (ERD, data dictionary), `errors.py`, `README.md`, `tests/` |

`schema.sql` runs: schema_incident.sql, schema_people.sql, objects_a.sql, objects_b.sql.

## Naming
Tables `Singular_Pascal_Case`, columns `snake_case`, procedures `sp_VerbNoun`, functions `fn_Name`, views `v_name`, triggers `trg_table_action`, indexes `ix_table_columns`. Error codes: A 50100-50199, B 50200-50299.
Every SQL object has a 3-line header comment: what, why (viva), who.

## Commit messages
Start with the task ID: `A1: add incident schema tables`, `B3: add sp_StartInvestigation`.

## Never commit
`.env`, real passwords, `.bak` files. Ship `.env.example` only.
