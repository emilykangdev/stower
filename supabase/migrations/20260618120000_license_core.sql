-- License core schema: the two tables that make trial mint idempotent and the
-- Lemon Squeezy upgrade webhook replay-safe. See the reference plan
-- §What Persistence (tmp/ready-plans/2026-06-18-keygen-trial-supabase.md).

-- One row per device. The mint-trial idempotency guard (closes B2): a mint that
-- dies mid-flow neither double-mints nor returns null ids, because the row's
-- `status` lifecycle (pending -> active) is the claim, not a Keygen lookup.
create table if not exists device_trials (
    fingerprint        text primary key,                  -- SHA-256 hex of IOPlatformUUID; the dedupe key
    status             text not null default 'pending',   -- 'pending' (claimed, mint in flight) | 'active' (id/key set)
    keygen_license_id  text unique,                       -- Keygen license RESOURCE id (UUID, NOT the secret key); UNIQUE so it is a valid FK target
    keygen_license_key text,                              -- the Keygen license KEY (the secret the app authenticates with); returned to the app
    created_at         timestamptz not null default now()
);

-- One row per processed Lemon Squeezy order. The webhook replay/idempotency
-- guard (closes B7). The FK doubles as an anti-forgery check on the
-- client-controlled custom_data.license_id: a webhook naming a license we never
-- minted hits the FK violation, which the webhook catches and returns 200.
create table if not exists purchases (
    ls_order_id        text primary key,                  -- Lemon Squeezy order id; dedupe so a replayed webhook is a no-op
    keygen_license_id  text not null
                         references device_trials (keygen_license_id),
    email              text not null,                     -- buyer email (receipts/support; NOT a join key)
    ls_variant_id      text not null,                     -- validated against the Stower paid variant before upgrading
    processed_at       timestamptz not null default now() -- written ONLY after a successful policy upgrade
);
