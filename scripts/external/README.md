External buffer builder (for DO droplet)

Goal
- Build the heavy buffered footprint off-DB and write a single MultiPolygon row into runmap.coverage_buffer_external.
- Postgres then serves this geometry via runmap.coverage_buffer_current.

Apply DB migration first (on your local machine)
- source .env
- psql "host=$PGLONG_HOST port=$PGLONG_PORT dbname=$PGLONG_DB user=$PGLONG_USER password=$PGPASSWORD sslmode=require" -v ON_ERROR_STOP=1 -f db/migrations/0025_external_buffer_current_and_rewire.sql

Requirements on droplet
- Python 3.11+
- git clone your repo to e.g. /opt/runmap
- cd /opt/runmap
- python3 -m venv venv && source venv/bin/activate
- pip install -r scripts/external/requirements.txt
- Create env file: sudo mkdir -p /etc/runmap && sudo cp scripts/external/systemd/runmap-buffer.env.example /etc/runmap/runmap-buffer.env
- Edit /etc/runmap/runmap-buffer.env with your PG creds (Session Pooler 5432)

Manual run
- source /opt/runmap/venv/bin/activate
- cd /opt/runmap
- python scripts/external/build_fast_buffer.py
- Then refresh dependents:
  - psql "host=$PGHOST port=$PGPORT dbname=$PGDATABASE user=$PGUSER password=$PGPASSWORD sslmode=require" -c "SET statement_timeout=0; SELECT public.refresh_after_external();"

Set up systemd scheduling (hourly)
- sudo cp scripts/external/systemd/runmap-buffer.service.tmpl /etc/systemd/system/runmap-buffer.service
- sudo cp scripts/external/systemd/runmap-buffer.timer.tmpl   /etc/systemd/system/runmap-buffer.timer
- Edit /etc/systemd/system/runmap-buffer.service:
  - Set WorkingDirectory to the repo path (e.g., /opt/runmap)
- sudo systemctl daemon-reload
- sudo systemctl enable --now runmap-buffer.timer
- Check: systemctl list-timers | grep runmap-buffer
- Logs: journalctl -u runmap-buffer.service -n 200 -f

Tuning knobs in the script
- SIMPLIFY_TOLERANCE_M (default 10.0)
- SNAP_GRID_M (default 1.0)
- Set in /etc/runmap/runmap-buffer.env

Notes
- No secrets in repo. Use /etc/runmap/runmap-buffer.env on the droplet.
- The script uses Shapely/GEOS and pyproj to do CPU-heavy work outside Postgres.
