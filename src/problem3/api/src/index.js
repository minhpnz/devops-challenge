const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const app = express();

const PORT = Number(process.env.PORT || 3000);
const SHUTDOWN_TIMEOUT_MS = 10000;

const pool = new Pool({
  host: process.env.DB_HOST || "postgres",
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || "postgres",
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME || "postgres",
  max: Number(process.env.DB_POOL_MAX || 10),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// Without this listener an idle client dropped by Postgres kills the process.
pool.on("error", (err) => {
  console.error("pg idle client error:", err.message);
});

const redis = new Redis({
  host: process.env.REDIS_HOST || "redis",
  port: Number(process.env.REDIS_PORT || 6379),
  lazyConnect: true,
  enableOfflineQueue: false,
  maxRetriesPerRequest: 1,
  connectTimeout: 2000,
  retryStrategy: (times) => Math.min(times * 200, 5000),
});

redis.on("error", (err) => {
  console.error("redis error:", err.message);
});

redis.connect().catch((err) => {
  console.error("redis initial connect failed:", err.message);
});

app.get("/api/users", async (req, res) => {
  let db;
  try {
    db = await pool.connect();
    const result = await db.query("SELECT NOW()");

    // Redis is a cache here, not a source of truth. A cache outage must not
    // turn a working read into a 500.
    redis.set("last_call", Date.now()).catch((err) => {
      console.error("redis set failed:", err.message);
    });

    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    console.error("GET /api/users failed:", err.message);
    res.status(500).json({ ok: false, error: "internal error" });
  } finally {
    if (db) db.release();
  }
});

// Liveness: is the process alive? Never touches dependencies, so a DB outage
// does not make the orchestrator kill an otherwise healthy container.
app.get("/health", (req, res) => {
  res.json({ status: "ok" });
});

// Readiness: can this instance actually serve traffic?
app.get("/ready", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ready", redis: redis.status });
  } catch (err) {
    res.status(503).json({ status: "not ready", error: err.message });
  }
});

app.get("/status", (req, res) => {
  res.json({ status: "ok" });
});

const server = app.listen(PORT, () => console.log(`API running on ${PORT}`));

function shutdown(signal) {
  console.log(`${signal} received, draining`);

  const timer = setTimeout(() => {
    console.error("drain timed out, forcing exit");
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS);

  server.close(async () => {
    clearTimeout(timer);
    try {
      await pool.end();
      redis.disconnect();
    } catch (err) {
      console.error("cleanup error:", err.message);
    }
    process.exit(0);
  });
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

process.on("unhandledRejection", (err) => {
  console.error("unhandled rejection:", err);
});
