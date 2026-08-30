# Problem 3 — Debugging Issues Within System

The report is "the API is unreliable and sometimes inaccessible". That phrasing is worth
taking seriously before touching anything: *inaccessible* and *unreliable* are two different
complaints. Something that is always broken is one bug. Something that is intermittently
broken is usually a different bug, and often several. I went looking for both.

I found five. Four of them I found by reading and testing; the fifth only showed up because
I tried to break my own fix.

---

## How I worked

1. Read every file before running anything, so I'd recognise something odd when I saw it.
2. Reproduce the symptom exactly as reported.
3. For each layer boundary (client → nginx → api → postgres/redis), find out which side of
   the boundary is broken instead of guessing.
4. One hypothesis at a time, tested in isolation.
5. Fix, then re-run the exact experiment that demonstrated the bug.


---

## Step 1 — Reproduce

```
$ docker compose up --build -d
$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/
200

$ for i in 1 2 3; do curl -s -m 10 -w "http=%{http_code} time=%{time_total}s\n" \
    -o /dev/null http://localhost:8080/api/users; done
http=502 time=0.003281s
http=502 time=0.003083s
http=502 time=0.003170s
```

Two things stand out immediately.

`/` returns 200 but `/api/users` returns 502. So nginx is alive and serving — the problem is
between nginx and the API, not in front of nginx.

And the failures take **3 milliseconds**. That matters more than the status code. A timeout
would take seconds; 3ms means something refused the connection instantly. This isn't a slow
or overloaded backend, it's a backend that isn't there.

Also, while I was here:

```
$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/status
404
```

`/status` exists in the application but nginx has no route for it. Noted for later.

---

## Step 2 — Which side of the nginx→api boundary is broken?

The 502 could be nginx pointing at the wrong place, or the API being genuinely down. Rather
than assume, I asked both sides.

nginx:

```
$ docker compose logs nginx | grep -i error
[error] connect() failed (111: Connection refused) while connecting to upstream,
  upstream: "http://172.20.0.4:3001/api/users"
```

The API:

```
$ docker compose logs api
API running on 3000

$ docker compose exec api netstat -tlnp | grep LISTEN
tcp  0  0 :::3000  :::*  LISTEN  1/node
```

There it is. nginx dials **3001**, the API listens on **3000**. `Connection refused` at 3ms
is exactly what you'd expect — the container is up, nothing is bound to that port, the kernel
rejects the SYN immediately.

### Root cause 1 — port mismatch

`nginx/conf.d/default.conf` had `proxy_pass http://api:3001;` while `api/src/index.js` calls
`app.listen(3000)`. Nothing in the stack could have worked. Confirmed by bypassing nginx
entirely:

```
$ docker compose exec api wget -qO- http://localhost:3000/api/users
{"ok":true,"time":{"now":"2026-08-30T09:47:23.840Z"}}
```

The API is fine. Only the route to it was wrong.

**This explains "inaccessible" — but not "unreliable".** A port typo is 100% broken, 100% of
the time. Users reporting *intermittent* trouble means there's something else, and if I'd
stopped here I'd have shipped a fix that looked complete and left the real incident in place.

---

## Step 3 — Hunting the intermittent failure

The API works when reached directly, so whatever is intermittent must depend on something
that changes over time. The two candidates are the dependencies: Postgres and Redis.

I simulated the most ordinary thing that happens to a database — a restart (maintenance,
failover, OOM, node replacement):

```
$ docker compose exec api wget -qO- http://localhost:3000/api/users   # prime the pool
{"ok":true,...}

$ docker inspect -f 'running={{.State.Running}} restarts={{.RestartCount}}' problem3-api-1
running=true restarts=0

$ docker compose restart postgres && sleep 8

$ docker inspect -f 'running={{.State.Running}} restarts={{.RestartCount}}' problem3-api-1
running=false restarts=0
```

The API process died. And `restarts=0` — nothing brought it back. It stayed dead.

The logs:

```
      throw er; // Unhandled 'error' event
      ^
error: terminating connection due to administrator command
    at parseErrorMessage (/app/node_modules/pg-protocol/dist/parser.js:306:11)
```

### Root cause 2 — unhandled `error` event on the pg pool kills the process

`pg.Pool` is an EventEmitter. When Postgres drops a connection the pool is holding idle, the
pool emits `error`. Node has a special rule for the `error` event: if nothing is listening, it
doesn't get swallowed, it gets **rethrown as an uncaught exception**. The code never
registered `pool.on("error", ...)`, so a routine database blip terminates the API.

### Root cause 3 — no restart policy

Compose had no `restart:` on any service. So once the process exits, the container stays
down until a human notices. This is what converts a two-second database blip into an outage
that lasts until someone gets paged.

These two together explain the user report precisely. The database restarts occasionally
→ the API dies → it never comes back → the API is "sometimes inaccessible", and from the
user's side it looks random because it tracks database events they can't see.

---

## Step 4 — The connection leak

While reading the handler I noticed the error path:

```js
const db = await pool.connect();
const result = await db.query("SELECT NOW()");
db.release();                              // skipped if query() throws
```

`release()` is not in a `finally`. If `query()` throws, the client is never returned to the
pool. It's checked out forever.

That's a suspicion, not a finding, so I tested it. I ran both patterns side by side against
the real Postgres, forcing the query to fail each time and printing pool state:

```
===== OLD pattern: release() after query() =====
req  1  total=1  idle=0
req  2  total=2  idle=0
...
req 10  total=10 idle=0
req 11  total=10 idle=0  <-- POOL EXHAUSTED
req 12  total=10 idle=0  <-- POOL EXHAUSTED

===== NEW pattern: release() in finally =====
req  1  total=1  idle=1
req  2  total=1  idle=1
...
req 12  total=1  idle=1
```

### Root cause 4 — connections leaked on the error path

`total` climbs one per failure and `idle` never moves — every failed request permanently
consumes a pool slot. At 10 (node-postgres's default `max`) the pool is empty, and because
`connectionTimeoutMillis` defaults to 0 (wait forever), request 11 doesn't error — it
**hangs**. Requests pile up, nginx eventually times out, and the API is unresponsive while
its own process looks perfectly healthy.

This is the nastiest of the five, because it's cumulative and silent. It needs ten failures
to trigger, so it shows up as "the API gets bad after a while and a restart fixes it".

---

## Step 5 — Two more things that were simply never wired up

**`postgres/init.sql` was never applied.** It contains
`ALTER SYSTEM SET max_connections = 20;`, but the postgres service had no volume mount:

```
$ docker compose exec postgres ls -la /docker-entrypoint-initdb.d/
total 8          # empty

$ docker compose exec postgres psql -U postgres -tAc "SHOW max_connections;"
100
```

So the file was dead config. Worth flagging both halves: it wasn't being applied, *and* the
value in it is wrong. 20 connections against a pool of 10 per API instance means two
replicas exhaust the database, with nothing left for `psql`, backups, or monitoring.

**Startup ordering.** `depends_on` without a condition only waits for the container to be
*created*, not for the service inside it to be *ready*. Postgres takes a few seconds to
accept connections. The API starts immediately and its first queries fail — which, thanks to
root cause 4, leaks a connection each time, and thanks to root cause 2, can kill the process
outright. The three bugs compound each other at every single startup.

---

## Step 6 — The one I only found by attacking my own fix

After fixing the four above I re-ran the failure scenarios. Then I tried something the
original report hints at: what happens when the API container is replaced and gets a
different IP? (Every deploy, OOM kill, or crash-restart can do this.)

```
$ docker compose stop api
$ docker run -d --name squat1 --network problem3_default alpine sleep 300   # take the old IP
$ docker compose start api

api is now on: 172.21.0.8   (nginx had resolved 172.21.0.6)

$ curl -s -o /dev/null -w "http=%{http_code}\n" http://localhost:8080/api/users
http=502
http=502
http=502

$ docker compose logs nginx | grep error
[error] connect() failed (111: Connection refused) while connecting to upstream,
  upstream: "http://172.21.0.4:3000/api/users"
```

### Root cause 5 — nginx caches the upstream IP forever

nginx resolves hostnames in a static `upstream` block (or a literal `proxy_pass`) **once, at
config load**, and never again. When the API container comes back on a new address, nginx
keeps dialling the old one until somebody reloads it.

Note the failure signature: `connect() failed (111: Connection refused)`, 3ms — *identical*
to root cause 1. Two completely different bugs present the same way. This is why I kept
testing after the first fix rather than declaring victory: one 502 looks like any other.

The fix requires a `resolver` plus putting the target in a **variable**, because nginx only
re-resolves when the address comes from a variable:

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;   # Docker's embedded DNS

location /api/ {
    set $api_backend "http://api:3000";
    proxy_pass $api_backend;
}
```

Trade-off I accepted: a variable `proxy_pass` can't use an `upstream` block, so I lose
upstream keepalive and multi-server load balancing. At this traffic level, being reachable
matters more than saving a TCP handshake. With more than one API replica I'd revisit this —
either nginx Plus (`resolve` on the server directive), or a real service discovery layer.

---

## Summary of root causes

| # | Root cause | Symptom | Severity |
|---|---|---|---|
| 1 | nginx proxies to 3001, API listens on 3000 | every `/api/` request 502s | total outage |
| 2 | no `pool.on("error")` — unhandled event crashes Node | API dies on any DB blip | outage |
| 3 | no `restart:` policy | dead containers stay dead | turns blips into outages |
| 4 | `release()` outside `finally` — leaks on error path | pool exhausts after 10 errors, then hangs | slow degradation |
| 5 | nginx caches upstream IP forever | 502s after any API container replacement | outage |
| 6 | `init.sql` never mounted, and its value was wrong anyway | intended config silently absent | latent |
| 7 | `depends_on` without `condition` | failed queries at every startup | amplifies 2 and 4 |

---

## Fixes

### `nginx/conf.d/default.conf`
- `proxy_pass` to port **3000**.
- `resolver 127.0.0.11 valid=10s` with the target in a variable, so the IP is re-resolved.
- Added a `/status` route (it was 404 through nginx) and a `/healthz` for nginx's own check.
- Connect/send/read timeouts. Without them a hung upstream ties up a worker for 60s by
  default; a slow backend becomes a dead frontend.
- `X-Forwarded-For` / `X-Real-IP` / `X-Forwarded-Proto`, so the app can log real client IPs.

### `api/src/index.js`
- `pool.on("error")` — the crash fix.
- `release()` moved into `finally` — the leak fix.
- Pool bounded: `max`, `idleTimeoutMillis: 30000`, and `connectionTimeoutMillis: 5000` so
  exhaustion produces a fast 500 instead of an unbounded hang. Failing fast beats hanging;
  a hung request holds a socket and tells the caller nothing.
- **Redis demoted to what it is.** It was `await redis.set(...)` inside the try, so a Redis
  outage turned a perfectly good database read into a 500. It's a cache — the write is now
  fire-and-forget with its own error handler, plus `enableOfflineQueue: false` so commands
  fail fast instead of queueing in memory when Redis is gone.
- Split `/health` (liveness — process is up, touches nothing) from `/ready` (readiness —
  can actually reach Postgres). Using one endpoint for both is a trap: if the healthcheck
  hits the database, a brief DB problem makes the orchestrator kill every API container,
  turning a degradation into a total outage.
- Graceful shutdown on SIGTERM: stop accepting, drain in flight, close the pool, with a 10s
  hard cap so a stuck connection can't block shutdown forever.
- Credentials now come from the environment instead of being hardcoded in source.

### `docker-compose.yml`
- `restart: unless-stopped` on every service.
- Healthchecks on all four, and `depends_on: condition: service_healthy` so the API doesn't
  start until Postgres actually accepts connections.
- Mounted `init.sql`, added a named volume for Postgres data (it was ephemeral — every
  restart wiped the database).
- Credentials moved into `.env`, with `${POSTGRES_PASSWORD:?...}` so a missing value fails
  the stack loudly at startup rather than producing a confusing auth error later.
- Memory limit on the API so a leak can't take down the host.

### `api/Dockerfile`
- `npm ci` against a committed `package-lock.json` instead of `npm install` — the original
  had no lockfile, so two builds of the same commit could install different dependency
  versions. `--omit=dev` too.
- `USER node` — it was running as root.
- Added `.dockerignore`.

### Other
- `postgres/init.sql`: `max_connections` raised to 100 with the sizing reasoning written down.
- Deleted `nginx/nginx.conf` — an empty file that was never mounted. Dead config invites
  someone to edit it and wonder why nothing changes.

---

## Verification

Every fix was checked by re-running the experiment that exposed the bug.

**Original symptom**

```
$ curl -s -w " <- http=%{http_code} in %{time_total}s\n" http://localhost:8080/api/users
{"ok":true,"time":{"now":"2026-08-30T09:54:59.199Z"}} <- http=200 in 0.036991s
{"ok":true,...}                                        <- http=200 in 0.007461s
{"ok":true,...}                                        <- http=200 in 0.005331s

$ curl -s -w " <- http=%{http_code}\n" http://localhost:8080/status
{"status":"ok"} <- http=200
```

**Root cause 2 + 3 — Postgres restart**

```
before: running=true
after:  running=true restarts=0
recovery check: {"ok":true,...} <- http=200
api log: pg idle client error: terminating connection due to administrator command
```

The error is now logged and survived instead of being fatal. Previously: `running=false`.

**Root cause 4 — leak.** The A/B above: old pattern exhausts at 10, new pattern holds at
`total=1 idle=1` across 12 failures.

**Root cause 5 — IP change.** After the resolver fix, with the API forced onto a new address
and nginx never reloaded:

```
api is now on: 172.21.0.8   (nginx originally resolved 172.21.0.6)
http=200
http=200
http=200
http=200
```

**Redis outage**

```
$ docker compose stop redis
{"ok":true,...} <- http=200
{"ok":true,...} <- http=200
{"ok":true,...} <- http=200
```

Previously a 500.

**Clean rebuild**

```
$ docker compose down -v && docker compose up --build -d
stack healthy in 113s

NAME                  STATUS
problem3-api-1        running (healthy)
problem3-nginx-1      running (healthy)
problem3-postgres-1   running (healthy)
problem3-redis-1      running (healthy)

/            200
/healthz     200
/status      200
/api/users   200

100 requests: 100 x 200
```

One honest note: the first version of the nginx healthcheck used `wget`, which isn't in the
`nginx:1.25` image (`curl` is). It reported `unhealthy` on the clean run, I caught it in the
inspect output, and switched to `curl`. Mentioning it because a healthcheck that fails for
its own reasons is exactly the sort of thing that gets ignored as noise later.

---

## Monitoring and alerting I'd add

Every one of these maps to a specific failure above. I'd rather have five alarms that each
caught a real incident than thirty that nobody reads.

**Would have caught the crash loop (causes 2, 3)**
- Container restart count and uptime. Alert on any restart in production, and page on
  restart-loop. This was the single loudest available signal and nothing was watching it.
- Process start events in the logs. Repeated "API running on 3000" means repeated deaths.

**Would have caught the leak (cause 4)**
- Export `pool.totalCount`, `idleCount`, `waitingCount`. `waitingCount > 0` sustained is the
  leading indicator — it means requests are queueing for connections, and it appears
  *before* users notice. Alert at >0 for 2 minutes.
- `pg_stat_activity` connection count against `max_connections` on the database side, so you
  see it even if the app's own metrics are the thing that's broken.

**Would have caught the routing failures (causes 1, 5)**
- nginx 5xx rate by upstream. A sustained 502 rate is unambiguous.
- Blackbox probe against `/api/users` — end to end, through nginx, the way a user hits it.
  Both the port typo and the stale-IP bug would have fired this within a minute. Probing
  `/status` alone would have missed both, which is the argument for probing a route that
  actually exercises the dependencies.
- Alert specifically on `connect() failed` in nginx error logs. That string distinguishes
  "backend not there" from "backend slow", which is the first thing you want to know at 3am.

**Would have caught the dependency issues**
- `/ready` failure rate, separately from `/health`.
- Redis connection state — now that a Redis outage is non-fatal, it becomes *invisible*
  without a metric. Silent degradation is the price of graceful degradation, and the
  monitoring has to pay it back.

**Golden signals**, since they're what you look at first when something is wrong: request
rate, error rate, p50/p95/p99 latency, saturation (pool utilisation, memory against the
limit). Nothing exotic — Prometheus with `nginx-prometheus-exporter`, `postgres_exporter`,
and `prom-client` in the app covers all of it.

---

## Preventing this in production

**The port mismatch (cause 1)** — one integration test that starts the compose stack and
curls `/api/users` through nginx would have caught it in CI, in seconds. This is the highest
value item on the list: it's cheap and it catches an entire class of "the config and the code
disagree" bugs. Better still, have one source of truth for the port — an env var both the
app and the nginx config template read — so they can't drift.

**The crash (cause 2)** — a lint rule requiring error handlers on EventEmitters, and a
chaos test in CI that restarts the database mid-run and asserts the API survives. I ran that
test manually here; it should be automated, because this bug will be reintroduced.

**The leak (cause 4)** — code review is not a reliable control for `finally` blocks. Pool
metrics with an alarm are. Even better, wrap the acquire/release in a helper so handlers
can't get it wrong:

```js
async function withDb(fn) {
  const db = await pool.connect();
  try { return await fn(db); } finally { db.release(); }
}
```

Make the correct thing the only thing available.

**Config that isn't applied (cause 6)** — assert on effective configuration, not on the
presence of a file. A startup check or a test that runs `SHOW max_connections` and compares
against the expected value. The failure mode of dead config is silence, and silence needs an
active check.

**Generally**
- Healthchecks and `restart:` policies as a baseline requirement for any service, enforced in
  review or by a compose/Kubernetes lint rule.
- No `latest` tags; pin image versions (already true here, and worth keeping).
- Staging that mirrors production topology, so failures like the stale-IP one appear before
  customers find them.
- Run the dependency-failure drills deliberately — kill the database, kill Redis, replace the
  API container — on a schedule. Every bug in this report except the port typo only appears
  when something else fails first, and you don't discover those by testing the happy path.

---
