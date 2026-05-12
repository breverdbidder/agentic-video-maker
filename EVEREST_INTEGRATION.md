# EVEREST_INTEGRATION.md

End-to-end wiring for `breverdbidder/agentic-video-maker` into Everest infrastructure.

## TL;DR

```yaml
status: LIFTED (infrastructure ready, activation HITL-gated on 3 secrets)
fork: breverdbidder/agentic-video-maker
license: MIT (PERMISSIVE_FREE tier 4)
dispatch_path: chat → Supabase → pg_net → GHA → ffmpeg → artifact
activation_blockers:
  - vault.elevenlabs_api_key  (need account + key)
  - vault.fal_api_key         (need account + key)
  - vault.elevenlabs_voice_id_default  (pick from voice library)
runtime: GHA ubuntu-latest (ffmpeg native, free 2000 min/mo public)
cost_ceiling: $10/task (Everest rule), enforced in workflow guard step
```

## 1. One-time bootstrap (Ariel, ~10 min)

### 1a. ElevenLabs (~5 min, $0–22/mo)

1. Sign up at https://elevenlabs.io (Free tier OK for testing; Creator $22/mo for Music API + commercial use).
2. Profile → API Keys → Create new → copy key.
3. Voice Library → preview voices in Hebrew (e.g., search "multilingual") → copy a `voice_id` (long alphanumeric).
4. Insert into Supabase vault:

```sql
INSERT INTO vault.secrets (name, secret) VALUES
  ('elevenlabs_api_key', '<key>'),
  ('elevenlabs_voice_id_default', '<voice_id>');
```

### 1b. fal.ai (~3 min, pay-as-you-go)

1. Sign up at https://fal.ai → Dashboard → API Keys → create.
2. Add ~$5–10 starter credit (covers ~10 cheap or ~3 premium runs).
3. Insert into vault:

```sql
INSERT INTO vault.secrets (name, secret) VALUES
  ('fal_api_key', '<key>');
```

### 1c. Mirror vault → GHA secrets (~2 min)

GHA workflows can't read Supabase vault directly. Mirror once:

```bash
# Source vault values (one-time, never log)
ELEVEN=$(psql "$EVEREST_DB_URL" -tAc "SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='elevenlabs_api_key'")
FAL=$(psql "$EVEREST_DB_URL" -tAc "SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='fal_api_key'")
VOICE=$(psql "$EVEREST_DB_URL" -tAc "SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='elevenlabs_voice_id_default'")
GEMINI=$(psql "$EVEREST_DB_URL" -tAc "SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='gemini_api_key'")

# Push to GHA secrets (NAME ONLY in logs)
gh secret set GEMINI_API_KEY      -R breverdbidder/agentic-video-maker -b "$GEMINI"
gh secret set ELEVENLABS_API_KEY  -R breverdbidder/agentic-video-maker -b "$ELEVEN"
gh secret set FAL_KEY             -R breverdbidder/agentic-video-maker -b "$FAL"
gh secret set VOICE_ID            -R breverdbidder/agentic-video-maker -b "$VOICE"

# Optional (skip unless premium/ultra tier needed)
# gh secret set XAI_API_KEY -R breverdbidder/agentic-video-maker -b "$XAI"
# gh secret set OPENAI_API_KEY -R breverdbidder/agentic-video-maker -b "$OPENAI"
```

Per cred-hygiene rules: never `echo` the variables, never paste them into commit messages, issues, or PR descriptions.

## 2. Smoke test (HITL gate cleared → optional sanity check)

Trigger the workflow manually with a cheap-tier request:

```bash
gh workflow run "Everest Video Dispatch" \
  -R breverdbidder/agentic-video-maker \
  -f brief="5-second test card with the word HELLO on a black background" \
  -f length=5 \
  -f quality=cheap \
  -f max_cost=1
```

Expected: workflow completes in ~5–10 min, uploads `video-p_xxx.mp4` artifact, costs <$1.

## 3. Summit dispatch path (production)

Once smoke-tested, dispatch from chat via summit_chat_dispatch:

```sql
-- Example: ZoneWise GTM video request
INSERT INTO summit_chat_dispatch (request_type, payload, status)
VALUES (
  'video_make',
  jsonb_build_object(
    'event_type', 'everest_video_request',
    'repo', 'breverdbidder/agentic-video-maker',
    'client_payload', jsonb_build_object(
      'brief',  'ZoneWise.AI: 30s explainer showing how to instantly look up zoning for any FL parcel — modern, tech aesthetic, English voiceover',
      'length', 30,
      'quality','medium',
      'look',   'tech',
      'max_cost', 3,
      'critique_loop', true,
      'target_score', 8.0,
      'run_id', gen_random_uuid()::text
    )
  ),
  'queued'
);
```

The existing pg_cron job (1-min tick) picks up `queued` rows, calls `pg_net.http_post` to the GitHub dispatches endpoint with the `everest_gh_pat` from vault, and updates row to `dispatched`. Sentinel TTL rules apply (queued→dispatched 60s).

## 4. Callback table (TODO before first production run)

```sql
-- Recommended schema. Apply when ready to enable callbacks.
CREATE TABLE IF NOT EXISTS video_generation_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  request_brief   text NOT NULL,
  request_payload jsonb NOT NULL,
  plan_id         text,
  gha_run_id      bigint,
  gha_run_url     text,
  status          text NOT NULL DEFAULT 'queued'
                  CHECK (status = ANY (ARRAY['queued','dispatched','planning','producing','critique','complete','failed','quarantined'])),
  cost_estimate_usd numeric(6,2),
  cost_actual_usd   numeric(6,2),
  critique_final_score numeric(3,1),
  critique_rounds_used int,
  artifact_url    text,
  error_message   text,
  completed_at    timestamptz
);
CREATE INDEX idx_vgr_status ON video_generation_runs(status) WHERE status IN ('queued','dispatched','planning','producing','critique');
CREATE INDEX idx_vgr_plan_id ON video_generation_runs(plan_id);
```

The workflow's "Callback (Supabase)" step is currently a TODO stub — wire it once this table exists.

## 5. Sentinel hooks

Add to `sentinel.yml` watch list (per AUTOLOOP V2 + Sentinel discipline):

```yaml
- name: video_maker_upstream_staleness
  source: github
  repo: Meir770ar/agentic-video-maker
  threshold_days: 90
  action: telegram_notify
  message: "Upstream agentic-video-maker has been silent {days}d — abandonware risk, consider unforking"

- name: video_maker_workflow_failures
  source: github_actions
  repo: breverdbidder/agentic-video-maker
  workflow: Everest Video Dispatch
  pattern_3xfailed: true
  action: telegram_notify + insert_honesty_violation
```

## 6. Pattern extraction (separate work stream)

The reason this fork is REFERENCE_ONLY-with-LIFT, not pure ADOPT, is that the *pattern* is the higher-value lift than the *product*. See `CLAUDE.md` § "Pattern-extraction TODOs":

1. Port `scripts/patch-plan.cjs` JSON-path patcher → AUTOLOOP V2 evolver (P1, ~2hr)
2. Adopt `plan_patch:{field,new_value}` schema for signal_detector outputs (P1, ~1hr)
3. Mine senior-editor SYSTEM_PROMPT severity taxonomy → verifier prompts (P2, ~1hr)
4. **Pre-extraction audit** (15 min): `grep -rn "plan_patch\|parsePath\|setPath" cli-anything-biddeed/` — skip 1–3 if AUTOLOOP V2 already does this.

Do the audit first. The user already runs this discipline ("Company Brain hype check" pattern).

## 7. Cost forecast (first month of operation)

```yaml
expected_volume:
  smoke_tests: 2-3 runs   # one-time validation, ~$3 total
  production_runs: 4-8/mo # ZoneWise + BidDeed GTM content, mostly medium tier
  per_run_avg: $2.50      # medium quality, critique-loop on, 2 rounds avg
  monthly_estimate: $20-30/mo
ceiling_check:
  - Everest $100/mo API budget: OK (this is <30% of budget)
  - $10/task ceiling: enforced in workflow guard step (hard fail)
```

## 8. Open questions / unknowns

- ElevenLabs Hebrew voice quality at `eleven_v3` — needs subjective check before committing to Hebrew GTM content
- Whether GTM video is on roadmap at all — pre-Sprint 1 the answer was "no"; revisit after ZoneWise free-tier launch
- Sora-2 / Veo-3 access (gated): not required for this lift, but may want once available
