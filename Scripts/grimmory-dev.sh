#!/usr/bin/env bash
# A local Grimmory test server in Podman, for developing Bow without a home lab.
#
# Mirrors Grimmory's own Podman quadlets (deploy/podman/quadlet): one pod publishing port 6060, with MariaDB 11.4.8
# and Grimmory sharing localhost, named volumes, and the database password as a Podman secret.
#
#   Scripts/grimmory-dev.sh up       start it (first run also creates the admin account and a library)
#   Scripts/grimmory-dev.sh down     stop it (data is kept)
#   Scripts/grimmory-dev.sh status   show containers and whether the server answers
#   Scripts/grimmory-dev.sh rescan   pick up books added to ~/GrimmoryDev/books
#   Scripts/grimmory-dev.sh logs     follow Grimmory's log
#   Scripts/grimmory-dev.sh reset    delete everything, including the database and the test account
#
# Books: drop EPUBs into ~/GrimmoryDev/books, then run `rescan`. File-change events don't cross from macOS into the
# Podman VM, so Grimmory's folder watching doesn't see them.
# Test account and server URL: .grimmory-dev.env at the repo root (gitignored).
set -euo pipefail

IMAGE="${GRIMMORY_IMAGE:-ghcr.io/grimmory-tools/grimmory:v3.5.0}"
DB_IMAGE="lscr.io/linuxserver/mariadb:11.4.8"
POD=grimmory-dev
PORT="${GRIMMORY_PORT:-6060}"
URL="http://127.0.0.1:${PORT}"
HOST_DIR="${GRIMMORY_DEV_DIR:-$HOME/GrimmoryDev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.grimmory-dev.env"

ensure_machine() {
  if ! podman info >/dev/null 2>&1; then
    echo "Starting the Podman machine…"
    podman machine start >/dev/null
  fi
}

random() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

wait_for_server() {
  echo -n "Waiting for Grimmory to answer"
  for _ in $(seq 1 90); do
    if curl -fs -m 3 "$URL/api/v1/healthcheck" >/dev/null 2>&1; then echo " ready."; return 0; fi
    echo -n "."; sleep 2
  done
  echo; echo "Grimmory didn't come up in 3 minutes. See: $0 logs" >&2; return 1
}

json() { python3 -I -c "import json,sys; print(json.load(sys.stdin)$1)"; }

first_run_setup() {
  [[ -f "$ENV_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  # Each step checks for itself, so an interrupted first run finishes on the next `up`.
  if [[ "$(curl -fs "$URL/api/v1/setup/status" | json "['data']")" != "True" ]]; then
    echo "Creating the admin account…"
    curl -fsS -X POST "$URL/api/v1/setup" -H 'Content-Type: application/json' \
      -d "{\"username\":\"$GRIMMORY_USERNAME\",\"password\":\"$GRIMMORY_PASSWORD\",\"name\":\"Bow Tester\",\"email\":\"tester@example.invalid\"}" >/dev/null
  fi

  local token
  token=$(curl -fsS -X POST "$URL/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$GRIMMORY_USERNAME\",\"password\":\"$GRIMMORY_PASSWORD\"}" | json "['accessToken']")

  if [[ "$(curl -fsS "$URL/api/v1/libraries" -H "Authorization: Bearer $token" | json ".__len__()")" == "0" ]]; then
    echo "Creating the \"Test Library\" library on /books…"
    # Grimmory v3.5.0 icons are Lucide names (or a custom SVG).
    curl -fsS -X POST "$URL/api/v1/libraries" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      -d '{"name":"Test Library","icon":"book-open","iconType":"LUCIDE","paths":[{"path":"/books"}],"watch":true}' >/dev/null
  fi
}

up() {
  ensure_machine
  mkdir -p "$HOST_DIR/books" "$HOST_DIR/bookdrop"

  if [[ ! -f "$ENV_FILE" ]]; then
    umask 077
    cat >"$ENV_FILE" <<EOF
# Local Grimmory test server (Scripts/grimmory-dev.sh). Throwaway credentials for this machine only.
GRIMMORY_URL=$URL
GRIMMORY_USERNAME=tester
GRIMMORY_PASSWORD=$(random 20)
GRIMMORY_DB_PASSWORD=$(random 24)
EOF
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  if ! podman secret exists grimmory_dev_db_pass; then
    printf '%s' "$GRIMMORY_DB_PASSWORD" | podman secret create grimmory_dev_db_pass - >/dev/null
  fi

  if podman pod exists "$POD"; then
    podman pod start "$POD" >/dev/null
  else
    echo "Pulling images (first run only)…"
    podman pull -q "$DB_IMAGE" >/dev/null
    podman pull -q "$IMAGE" >/dev/null
    podman volume create --ignore grimmory-dev-db >/dev/null
    podman volume create --ignore grimmory-dev-data >/dev/null
    podman pod create --name "$POD" -p "127.0.0.1:${PORT}:6060" >/dev/null

    podman run -d --pod "$POD" --name grimmory-dev-db \
      -v grimmory-dev-db:/config \
      -e TZ=Etc/UTC -e PUID=0 -e PGID=0 \
      -e MYSQL_USER=grimmory -e MYSQL_DATABASE=grimmory \
      --secret grimmory_dev_db_pass,type=env,target=MYSQL_ROOT_PASSWORD \
      --secret grimmory_dev_db_pass,type=env,target=MYSQL_PASSWORD \
      --health-cmd 'mariadb-admin ping -h localhost' --health-interval 5s \
      "$DB_IMAGE" >/dev/null

    echo -n "Waiting for MariaDB"
    for _ in $(seq 1 60); do
      if podman healthcheck run grimmory-dev-db >/dev/null 2>&1; then echo " ready."; break; fi
      echo -n "."; sleep 2
    done

    podman run -d --pod "$POD" --name grimmory-dev \
      -v grimmory-dev-data:/app/data \
      -v "$HOST_DIR/books:/books" \
      -v "$HOST_DIR/bookdrop:/bookdrop" \
      -e TZ=Etc/UTC \
      -e DATABASE_URL=jdbc:mariadb://localhost:3306/grimmory \
      -e DATABASE_USERNAME=grimmory \
      --secret grimmory_dev_db_pass,type=env,target=DATABASE_PASSWORD \
      -e API_DOCS_ENABLED=true \
      "$IMAGE" >/dev/null
  fi

  wait_for_server
  first_run_setup
  echo
  echo "Grimmory is running at $URL (API docs at $URL/api/docs)."
  echo "Sign in with the test account in .grimmory-dev.env. Books go in $HOST_DIR/books."
}

down() {
  podman pod stop "$POD" >/dev/null 2>&1 || true
  echo "Stopped. Data is kept; '$0 up' starts it again."
}

status() {
  podman pod ps --filter "name=$POD"
  podman ps -a --pod --filter "pod=$POD" --format '{{.Names}}\t{{.Status}}'
  # /api/v1/version needs a signed-in user; the healthcheck doesn't.
  if curl -fs -m 3 "$URL/api/v1/healthcheck" >/dev/null 2>&1; then echo "Grimmory is answering at $URL"; else echo "Server not answering at $URL"; fi
}

rescan() {
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  local token
  token=$(curl -fsS -X POST "$URL/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$GRIMMORY_USERNAME\",\"password\":\"$GRIMMORY_PASSWORD\"}" | json "['accessToken']")
  for id in $(curl -fsS "$URL/api/v1/libraries" -H "Authorization: Bearer $token" \
      | python3 -I -c "import json,sys; print(' '.join(str(l['id']) for l in json.load(sys.stdin)))"); do
    curl -fsS -X PUT "$URL/api/v1/libraries/$id/refresh" -H "Authorization: Bearer $token" >/dev/null
  done
  echo "Rescanning. New books show up in a few seconds."
}

reset() {
  podman pod rm -f "$POD" >/dev/null 2>&1 || true
  podman volume rm -f grimmory-dev-db grimmory-dev-data >/dev/null 2>&1 || true
  podman secret rm grimmory_dev_db_pass >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"
  echo "Removed the pod, its volumes, the secret and the test account. Books in $HOST_DIR are untouched."
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  status) status ;;
  rescan) rescan ;;
  logs) podman logs -f grimmory-dev ;;
  reset) reset ;;
  *) echo "usage: $0 [up|down|status|rescan|logs|reset]" >&2; exit 2 ;;
esac
