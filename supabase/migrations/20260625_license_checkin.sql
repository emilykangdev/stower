-- License check-in schema: the additive columns + table that let the Edge
-- Function own runtime check-in, server-side machine activation/checkout, and the
-- once-per-major +7-day trial extension. See Docs/licensing-contract.md v1.13 and
-- tmp/ready-plans/2026-06-25-supabase-licensing-backend.md.
--
-- Additive only. The base schema (20260618120000_license_core.sql) keeps its
-- fingerprint PK, status/claim_id lifecycle, keygen_license_id (UNIQUE FK target),
-- and keygen_license_key. This migration adds, never drops, so a re-run is safe.

-- device_trials grows the state check-in reads and writes: the activated machine
-- (so checkout can reuse it), the major the trial started under (extension
-- eligibility), an explicit updated_at (written by every mutator — no trigger),
-- and the last check-in time for support + diagnostics.
alter table device_trials
  add column if not exists keygen_machine_id   text,
  add column if not exists started_major       text not null default 'v0',
  add column if not exists updated_at           timestamptz not null default now(),
  add column if not exists last_check_in_at     timestamptz;

-- One row per (license, major) extension grant. The PK caps each major at exactly
-- one +7d (JC8 / I11). The grant is recorded BEFORE the Keygen expiry patch, to a
-- FIXED target_expires_at, so a crash between record and patch re-converges to +7
-- exactly once on retry (the patch is target-state, not a delta).
create table if not exists trial_extension_grants (
  keygen_license_id   text not null references device_trials (keygen_license_id),
  major               text not null,
  previous_expires_at timestamptz not null,
  target_expires_at   timestamptz not null,
  patched_at          timestamptz,
  created_at          timestamptz not null default now(),
  primary key (keygen_license_id, major)
);

-- Service-role only, no policies — same lockdown as device_trials/purchases. The
-- table holds no secret, but it is licensing state and must not be reachable
-- through the public anon/authenticated PostgREST API.
alter table trial_extension_grants enable row level security;

-- purchases records which major a paid order unlocked, so a paid license carries
-- the major it bought (the webhook stamps these alongside attaching STOWER_V0).
alter table purchases
  add column if not exists purchased_major  text not null default 'v0',
  add column if not exists entitlement_code text not null default 'STOWER_V0';
