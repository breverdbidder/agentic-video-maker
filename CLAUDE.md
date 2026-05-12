# CLAUDE.md — agentic-video-maker (Everest fork)

> Forked from `Meir770ar/agentic-video-maker` (MIT). Upstream is the source of pipeline truth; this file governs how Everest uses, dispatches, and budgets it.

## Status

- **Verdict**: REFERENCE_ONLY → LIFTED. `extrep_evaluations.intake_id=01cf8cac-7a33-488a-bfdf-d0849293f1ff`.
- **License**: MIT → tier 4 PERMISSIVE_FREE → FORK-OK + USE-OK + MODIFY-OK. Keep upstream `LICENSE` file and copyright header intact.
- **Upstream remote**: `git remote -v` shows `upstream` → `Meir770ar/agentic-video-maker`. Sync via `git fetch upstream && git merge upstream/master` only when upstream ships.

## What this repo does (one-screen)

Brief → Gemini script → ElevenLabs narration + fal.ai/xAI visuals + music → ffmpeg compose → Gemini Video critique (structured JSON: P0/P1/P2 issues + `plan_patch{field, new_value}`) → whitelisted dotted-path patcher (`patch-plan.cjs`) → mark affected scenes pending → re-render → loop until `overall_score >= --critique-target-score` (default 8.5) or `--critique-max-rounds` (default 3).

The critique-loop pattern is conceptually parallel to **AUTOLOOP V2** (Dify verifier → signal_detector → RCA → evolver, ratified Mar 30 2026). Different domain, same shape.

## HITL gates (do NOT silently bypass)

| Gate | Reason | Resolver |
|---|---|---|
| ElevenLabs account + API key | New 3rd-party service, $-spend | Ariel: sign up, paste key into vault as `elevenlabs_api_key` |
| fal.ai account + API key | New 3rd-party service, $-spend | Ariel: sign up, paste key into vault as `fal_api_key` |
| VOICE_ID selection | Multilingual voice for Hebrew RTL | Ariel: pick from elevenlabs.io/app/voice-library, store as `elevenlabs_voice_id_default` |
| First production run | `--max-cost` ceiling check | CC must use `--max-cost 10` (matches `$10/task` rule); higher = HITL |
| `--quality ultra` | $5–10/run, can stack with critique-loop | HITL per run unless approved batch |
| Any model behind `XAI_API_KEY` / `OPENAI_API_KEY` | New keys + new spend | HITL |

Mandatory env presence checks (the dispatch workflow already enforces these — see `.github/workflows/everest-dispatch.yml`):

```
GEMINI_API_KEY        # vault: gemini_api_key (present ✓)
ELEVENLABS_API_KEY    # vault: elevenlabs_api_key (MISSING — HITL)
FAL_KEY               # vault: fal_api_key (MISSING — HITL)
VOICE_ID              # vault: elevenlabs_voice_id_default (MISSING — HITL)
```

## Dispatch model (Everest-canonical)

This pipeline is heavy (ffmpeg + multi-API + multi-round). It runs as a **GHA workflow**, not inline in chat:

```
chat → Supabase MCP → summit_chat_dispatch (request_type='video_make')
     → pg_cron 1min → pg_net.http_post
     → POST /repos/breverdbidder/agentic-video-maker/dispatches
       (event_type='everest_video_request', client_payload={brief, length, quality, look, max_cost, plan_id?})
     → .github/workflows/everest-dispatch.yml
     → GHA runner (ubuntu-latest, has ffmpeg)
     → bash scripts/make-ai-video.sh ...
     → upload artifact (mp4 + critique.json + plan.json)
     → callback INSERT to Supabase: video_generation_runs(run_id, status, artifact_url, cost_estimate)
```

GHA runners include ffmpeg by default and run free for public repos (2000 min/month). LTX-2 + medium quality renders fit comfortably in a 60–90 min run with critique-loop on.

## Repo hygiene

- **Do not modify upstream files unnecessarily.** New Everest glue lives in `.github/`, `CLAUDE.md`, `EVEREST_INTEGRATION.md`, `harness/`. Touching `scripts/` only for upstream-able bug fixes.
- **Never embed secrets** in any file (per Apr 12–13 cred-hygiene rules). Workflows reference `${{ secrets.* }}` only. Local dev uses `.env` (already gitignored).
- **No `package-lock.json`** in scripts/ (already gitignored upstream — keep it that way).
- **Sync from upstream**: `git fetch upstream && git merge upstream/master --no-edit` — resolve conflicts in favor of upstream for `scripts/`, in favor of fork for `.github/`, `CLAUDE.md`, `EVEREST_INTEGRATION.md`.

## Pattern-extraction TODOs (cross-repo, P1)

These are patterns to lift FROM this repo INTO Everest core, separate from running the video pipeline:

1. **Port `scripts/patch-plan.cjs` pattern** (parsePath + AUTO_CREATE_ROOTS + coerce + exit-code semantics) into AUTOLOOP V2 evolver as standardized JSON-path patch utility. ~2hr. Owner: Claude Code.
2. **Adopt `plan_patch: {field, new_value}` JSON contract** for signal_detector outputs. ~1hr. Owner: Claude AI Architect.
3. **Mine senior-editor SYSTEM_PROMPT + P0/P1/P2 severity taxonomy** from `scripts/gemini-critique.cjs` for verifier prompts. ~1hr. Owner: Claude AI Architect.
4. **Pre-extraction audit (15 min)**: `grep -rn "plan_patch\|parsePath\|setPath" cli-anything-biddeed/` to confirm AUTOLOOP V2 evolver doesn't already do this. Skip 1–3 if it does.

## Honesty (per Honesty V3)

- **VERIFIED**: License MIT, LOC counts (2211 total / 316 node / 145 in `patch-plan.cjs`), fork live at `breverdbidder/agentic-video-maker`, `gemini_api_key` present in vault, ffmpeg+node18+python3 install path works on GHA `ubuntu-latest`.
- **INFERRED**: Pattern transferability to AUTOLOOP V2 (based on code inspection, not yet tested).
- **ASSUMED**: AUTOLOOP V2 evolver currently lacks standardized JSON-path patcher (NOT verified — 15-min grep audit is item 4 above).
- **UNKNOWN**: Whether anyone on team wants video GTM content for ZoneWise/BidDeed; whether ElevenLabs Hebrew voice quality clears bar.

## Cost ceiling (per Everest $10/task rule)

```yaml
cheap:   $0.50–1.00/run   # FLUX schnell + LTX-2, no critique-loop
medium:  $1.50–3.00/run   # nano-banana-2 + LTX-2, critique-loop optional
premium: $3.00–6.00/run   # nano-banana-2 + Grok Imagine, requires xAI key (HITL)
ultra:   $5.00–10.00/run  # A/B images + Grok Imagine, HITL per run
```

Critique-loop multiplier: ~1.0× per re-render round (cached scenes don't regen). 3 rounds ≈ 1.5–2× base cost.

`--max-cost 10` is the hard ceiling. Workflow aborts if estimate exceeds.

## Quick start (after HITL gates resolved)

```bash
# Populate vault (Ariel, one-time):
# INSERT INTO vault.secrets (name, secret) VALUES
#   ('elevenlabs_api_key', '<key>'),
#   ('fal_api_key', '<key>'),
#   ('elevenlabs_voice_id_default', '<voice_id>');

# Then test via GHA dispatch (replace placeholders):
curl -X POST \
  -H "Authorization: Bearer $EVEREST_GH_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/breverdbidder/agentic-video-maker/dispatches \
  -d '{"event_type":"everest_video_request","client_payload":{"brief":"30s ZoneWise zoning explainer, modern look, English","length":30,"quality":"medium","max_cost":3}}'
```
