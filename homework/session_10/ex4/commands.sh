#!/usr/bin/env bash
set -Eeuo pipefail
# Prevent Git Bash from rewriting Linux paths in docker arguments on Windows.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
export POSTGRES_USER=appuser
export POSTGRES_DB=appdb
# Lab credential only; override before running if needed. Never publish DB ports.
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-local-lab-password}"

# Refuse existing resources, so reruns cannot delete unrelated containers/data.
for name in db-server app-container; do
  if docker container inspect "$name" >/dev/null 2>&1; then
    echo "Container $name already exists; inspect it before rerunning." >&2
    exit 1
  fi
done
if docker volume inspect db-data >/dev/null 2>&1; then
  echo 'Volume db-data already exists; preserve it and inspect before rerunning.' >&2
  exit 1
fi
if docker network inspect app-net >/dev/null 2>&1; then
  echo 'Network app-net already exists; inspect before rerunning.' >&2
  exit 1
fi

# Generate a small backend that really connects to PostgreSQL (no host npm needed).
build_dir=$(mktemp -d)
trap 'rm -f -- "$build_dir/package.json" "$build_dir/server.js" "$build_dir/Dockerfile"; rmdir -- "$build_dir"' EXIT
cat > "$build_dir/package.json" <<'JSON'
{"name":"network-backend","version":"1.0.0","private":true,"dependencies":{"pg":"8.13.1"}}
JSON
cat > "$build_dir/server.js" <<'JS'
const http = require('http');
const { Pool } = require('pg');
const pool = new Pool(); // Reads PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE.
pool.on('error', err => console.error('Idle DB connection:', err.message));
http.createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  if (req.url !== '/') {
    res.writeHead(404);
    return res.end(JSON.stringify({ error: 'Not found' }));
  }
  try {
    const result = await pool.query('SELECT id, message FROM persistence_test ORDER BY id');
    res.writeHead(200);
    res.end(JSON.stringify({ status: 'success', dbHost: process.env.PGHOST, rows: result.rows }));
  } catch (err) {
    console.error('DB query failed:', err.message);
    res.writeHead(503);
    res.end(JSON.stringify({ status: 'error', message: 'Database unavailable' }));
  }
}).listen(3000, '0.0.0.0', () => console.log('Backend listening on port 3000; DB host=' + process.env.PGHOST));
JS
cat > "$build_dir/Dockerfile" <<'DOCKER'
FROM node:18-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.js ./
ENV PORT=3000
EXPOSE 3000
USER node
CMD ["node", "server.js"]
DOCKER
echo '=== Build backend ==='
(cd "$build_dir" && docker build -t hw-network-backend:v1 .)
echo '=== Create network and volume ==='
docker network create --driver bridge app-net
docker volume create db-data

start_db() {
  docker run -d --name db-server --network app-net \
    -e POSTGRES_USER -e POSTGRES_PASSWORD -e POSTGRES_DB \
    -v db-data:/var/lib/postgresql/data postgres:15-alpine
}
wait_db() {
  for attempt in $(seq 1 60); do
    # TCP confirms the final Postgres server, not the temporary init socket server.
    if docker exec db-server pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs db-server >&2
  echo 'PostgreSQL readiness timeout' >&2
  return 1
}
api_check() {
  docker exec app-container node -e '
    (async () => {
      const response = await fetch("http://127.0.0.1:3000/");
      const body = await response.json();
      console.log("HTTP " + response.status);
      console.log(JSON.stringify(body));
      if (response.status !== 200 || body.dbHost !== "db-server" ||
          body.rows.length !== 1 || body.rows[0].message !== "Du lieu ben vung Docker Volume") process.exit(1);
    })().catch(err => { console.error(err); process.exit(1); });'
}

echo '=== Start database and insert data ==='
start_db
wait_db
docker exec -i db-server psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE persistence_test (id integer PRIMARY KEY, message text NOT NULL);
INSERT INTO persistence_test VALUES (1, 'Du lieu ben vung Docker Volume');
SELECT * FROM persistence_test;
SQL
before=$(docker exec db-server psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc 'SELECT id, message FROM persistence_test ORDER BY id;')
old_id=$(docker inspect --format '{{.Id}}' db-server)

echo '=== Start backend with DB hostname ==='
export PGPASSWORD="$POSTGRES_PASSWORD"
docker run -d --name app-container --network app-net \
  -e PGHOST=db-server -e PGPORT=5432 -e PGUSER="$POSTGRES_USER" \
  -e PGPASSWORD -e PGDATABASE="$POSTGRES_DB" hw-network-backend:v1
for attempt in $(seq 1 30); do
  if docker exec app-container node -e 'fetch("http://127.0.0.1:3000/").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' >/dev/null 2>&1; then break; fi
  sleep 1
done
api_check

echo '=== DNS before recreation ==='
docker exec app-container ping -c 2 db-server

echo '=== Force-remove only the database container ==='
docker rm -f db-server

echo '=== Recreate database using the same named volume ==='
start_db
wait_db
new_id=$(docker inspect --format '{{.Id}}' db-server)
after=$(docker exec db-server psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc 'SELECT id, message FROM persistence_test ORDER BY id;')
printf 'Old container ID: %s\nNew container ID: %s\nBefore: %s\nAfter: %s\n' "$old_id" "$new_id" "$before" "$after"
[[ "$old_id" != "$new_id" ]]
[[ "$before" == '1|Du lieu ben vung Docker Volume' ]]
[[ "$before" == "$after" ]]
# No CREATE/INSERT is performed after the database container is recreated.
echo '=== Backend query after recreation ==='
api_check

echo '=== Required network and volume checks ==='
docker network ls | grep app-net
docker volume ls | grep db-data
docker network inspect app-net
docker exec app-container ping -c 2 db-server
docker ps --filter name=db-server --filter name=app-container
echo 'PASS: DNS resolved, backend queried PostgreSQL, data survived DB container replacement.'
