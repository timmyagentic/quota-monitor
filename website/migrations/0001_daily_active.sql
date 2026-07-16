CREATE TABLE daily_active_observations (
  day TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  version TEXT NOT NULL,
  brand TEXT NOT NULL,
  channel TEXT NOT NULL,
  PRIMARY KEY (day, token_hash)
) STRICT, WITHOUT ROWID;

CREATE TABLE daily_version_counts (
  day TEXT NOT NULL,
  version TEXT NOT NULL,
  brand TEXT NOT NULL,
  channel TEXT NOT NULL,
  active_count INTEGER NOT NULL CHECK(active_count >= 0),
  PRIMARY KEY (day, version, brand, channel)
) STRICT, WITHOUT ROWID;
