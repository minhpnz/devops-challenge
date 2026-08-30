-- Sized against the API pool: DB_POOL_MAX (10) x api replicas, plus headroom
-- for psql, pg_dump and monitoring. The original value of 20 left almost none.
ALTER SYSTEM SET max_connections = 100;
