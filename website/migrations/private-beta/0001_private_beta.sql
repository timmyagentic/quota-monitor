CREATE TABLE private_beta_enrollment_codes (
    code_digest TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER,
    CHECK (length(code_digest) = 64)
);

CREATE TABLE private_beta_devices (
    device_id TEXT PRIMARY KEY,
    token_digest TEXT NOT NULL UNIQUE,
    device_label TEXT NOT NULL,
    enrolled_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    revoked_at INTEGER,
    CHECK (length(token_digest) = 64),
    CHECK (length(device_label) BETWEEN 1 AND 120)
);

CREATE INDEX private_beta_devices_active_token
    ON private_beta_devices(token_digest)
    WHERE revoked_at IS NULL;
