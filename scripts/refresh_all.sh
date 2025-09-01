#!/usr/bin/env bash
set -euo pipefail

# Refresh runmap materialized views directly via Postgres with no timeout.
# Usage:
#   ./scripts/refresh_all.sh            # refresh_all (default)
#   ./scripts/refresh_all.sh quick      # refresh_quick (runs_collect, coverage_buffer_m)
#   ./scripts/refresh_all.sh fast       # refresh_quick_fast (coverage_buffer_m_fast only)
#
# Requires psql client and .env at repo root with:
#   PGHOST, PGPORT=6543, PGDATABASE=postgres, PGUSER=postgres.<ref>, PGPASSWORD

# Load .env from repo root regardless of CWD
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

: "${PGHOST:?Set PGHOST or add to .env}"
: "${PGPORT:=6543}"
: "${PGDATABASE:=postgres}"
: "${PGUSER:?Set PGUSER (e.g., postgres.<ref>) or add to .env}"
: "${PGPASSWORD:?Set PGPASSWORD or add to .env}"

MODE=${1:-all}
case "$MODE" in
all)   FN="runmap.refresh_all"        ;;
quick) FN="runmap.refresh_quick"      ;;
fast)  FN="runmap.refresh_quick_fast" ;;
 *) echo "Unknown mode '$MODE' (use 'all', 'quick', or 'fast')" >&2; exit 1 ;;
 esac

# Prefer direct (non-pooled) connection for long-running refreshes if provided
LONG_HOST=${PGLONG_HOST:-${PGHOST}}
LONG_PORT=${PGLONG_PORT:-${PGPORT}}
LONG_USER=${PGLONG_USER:-${PGUSER}}
LONG_DB=${PGLONG_DB:-${PGDATABASE}}

echo "Refreshing: $FN (statement_timeout=0)"
psql "host=${LONG_HOST} port=${LONG_PORT} dbname=${LONG_DB} user=${LONG_USER} password=${PGPASSWORD} sslmode=require application_name=refresh_all.sh" \
  -v ON_ERROR_STOP=1 \
  -c "SET client_min_messages = NOTICE; SET statement_timeout=0; SELECT ${FN}();"

echo "Done."
