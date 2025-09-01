-- Enable required extensions and create clean schema
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- for gen_random_uuid()

CREATE SCHEMA IF NOT EXISTS runmap;

-- Global settings (single row)
CREATE TABLE IF NOT EXISTS runmap.settings (
  id        integer PRIMARY KEY DEFAULT 1,
  buffer_m  integer NOT NULL DEFAULT 20,
  CONSTRAINT settings_one_row CHECK (id = 1)
);
INSERT INTO runmap.settings (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

-- Area of interest (optional, single row). If empty, we fall back to bbox around runs.
CREATE TABLE IF NOT EXISTS runmap.aoi (
  id   integer PRIMARY KEY DEFAULT 1,
  geom geometry(Polygon,4326)
);

-- Network to compare against (runnable subset inside AOI)
CREATE TABLE IF NOT EXISTS runmap.all_streets_runnable_aoi (
  street_id bigint PRIMARY KEY,
  name      text,
  geom      geometry(LineString,4326) NOT NULL
);
CREATE INDEX IF NOT EXISTS all_streets_runnable_aoi_gix
  ON runmap.all_streets_runnable_aoi USING GIST (geom);

-- Raw runs as uploaded (stored as MultiLineString for robustness)
CREATE TABLE IF NOT EXISTS runmap.runs_raw (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  start_time   timestamptz,
  duration_s   integer,
  distance_km  numeric(8,3),
  source_file  text,
  content_hash text UNIQUE NOT NULL,
  geom         geometry(MultiLineString,4326) NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS runs_raw_gix
  ON runmap.runs_raw USING GIST (geom);

-- RLS scaffolding (tighten in a separate migration)
ALTER TABLE runmap.runs_raw ENABLE ROW LEVEL SECURITY;
ALTER TABLE runmap.all_streets_runnable_aoi ENABLE ROW LEVEL SECURITY;
ALTER TABLE runmap.settings ENABLE ROW LEVEL SECURITY;
