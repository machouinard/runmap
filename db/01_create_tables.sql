-- Settings table
CREATE TABLE IF NOT EXISTS runmap.settings (
  key TEXT PRIMARY KEY,
  value JSONB,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insert default settings
INSERT INTO runmap.settings (key, value) VALUES
  ('buffer_distance_m', '20'::jsonb),
  ('tiles_version', to_jsonb(NOW()::text))
ON CONFLICT (key) DO NOTHING;

-- Runs (raw GPX tracks)
CREATE TABLE IF NOT EXISTS runmap.runs_raw (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  filename TEXT NOT NULL,
  uploaded_at TIMESTAMPTZ DEFAULT NOW(),
  start_time TIMESTAMPTZ,
  duration_seconds INTEGER,
  distance_km NUMERIC,
  geom geometry(MultiLineString, 4326) NOT NULL,
  content_hash TEXT UNIQUE NOT NULL,
  metadata JSONB
);

CREATE INDEX runs_raw_geom_idx ON runmap.runs_raw USING GIST(geom);
CREATE INDEX runs_raw_uploaded_idx ON runmap.runs_raw(uploaded_at DESC);

-- Streets reference (from OSM)
CREATE TABLE IF NOT EXISTS runmap.streets_reference (
  gid SERIAL PRIMARY KEY,
  osm_id BIGINT,
  name TEXT,
  highway TEXT,
  surface TEXT,
  geom geometry(LineString, 4326) NOT NULL,
  length_m NUMERIC GENERATED ALWAYS AS (ST_Length(geom::geography)) STORED,
  runnable BOOLEAN DEFAULT TRUE,
  neighborhood TEXT,
  CONSTRAINT valid_geom CHECK (ST_IsValid(geom))
);

CREATE INDEX streets_reference_geom_idx ON runmap.streets_reference USING GIST(geom);
CREATE INDEX streets_reference_runnable_idx ON runmap.streets_reference(runnable) WHERE runnable = TRUE;