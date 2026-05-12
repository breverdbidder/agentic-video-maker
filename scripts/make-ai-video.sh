#!/bin/bash
# agentic-video-maker — AI video pipeline with self-correcting critique loop
# https://github.com/<owner>/agentic-video-maker
#
# Pipeline:
#   Director (Gemini) → Prompt Engineer (Gemini) → Generators (Grok / Nano Banana / FLUX / LTX)
#   → ElevenLabs narration → music (ElevenLabs Music or local library) → HyperFrames + ffmpeg compose
#   → Gemini Video critique → auto-patch plan → re-render loop → WhatsApp-safe encode
#
# Modes: plan | revise | produce | regen-scene
# State: /tmp/ai-video-plans/<plan-id>.json
#
# Required env vars:
#   GEMINI_API_KEY        Google AI Studio key (Director, Prompt Engineer, Video critique)
#   ELEVENLABS_API_KEY    ElevenLabs (narration + Music API)
#   FAL_KEY               fal.ai (FLUX / nano-banana / LTX-2)
#   VOICE_ID              ElevenLabs voice ID for narration (REQUIRED — no default; use any public voice)
# Optional:
#   XAI_API_KEY           xAI (Grok Imagine) — only needed for --quality premium|ultra
#   GEMINI_CRITIQUE_MODEL Override critique model (default: gemini-2.5-flash)
#
# Flags:
#   --mode <m>            plan | revise | produce | regen-scene
#   --brief <text>        free-form video brief (any language)
#   --plan-id <id>        operate on an existing plan
#   --length N            target duration in seconds (10–60 typical)
#   --quality <q>         cheap | medium | premium | ultra
#   --look <l>            modern | warm | tech | luxury | minimal | medical | documentary | cinematic | classic
#   --aspects <a>         16:9 | 9:16 | 1:1 (comma-separated for multi-output)
#   --max-cost N          abort produce if estimated cost exceeds this (USD)
#   --voice <id>          ElevenLabs voice ID (overrides $VOICE_ID env)
#   --music-source <src>  musiclib | elevenlabs | auto (default: auto)
#   --music-prompt <txt>  custom prompt for ElevenLabs Music (default: derived from mood)
#   --critique <on|off>   Gemini Video critique after produce → JSON next to mp4 (default: off)
#   --critique-loop <on|off>   auto-apply patches + re-render until target score (default: off)
#   --critique-target-score N  stop loop when score >= N (default: 8.5)
#   --critique-max-rounds N    max iteration rounds (default: 3)
#   --scene-source N:path swap scene N's AI gen with an existing image/video file. Repeatable.
#   --brand <name>        brand label shown on outro card
#   --end-logo <path>     PNG path for end-card logo overlay
#   --captions on|off     burn word-sync captions (default: on)
#   --allowed-religious-context <ctx>  e.g. "jewish" — relaxes religious-imagery safety for that context only
set -e

# ───────── PATH augmentation ─────────
# If you install hyperframes / musiclib via npm -g, their bin dir may not be on PATH for non-login shells.
[ -d "$HOME/.npm-global/bin" ] && export PATH="$HOME/.npm-global/bin:$PATH"
[ -d "/usr/local/lib/node_modules/.bin" ] && export PATH="/usr/local/lib/node_modules/.bin:$PATH"

# ───────── Arg parsing ─────────
MODE=""; BRIEF=""; FEEDBACK=""; PLAN_ID=""; SCENE_NUM=""
LENGTH=30; QUALITY="medium"; LOOK=""; ASPECTS="16:9"; BRAND=""
END_LOGO=""; REFS=""; AB_HERO=""; TWO_STAGE=""; MAX_COST=10
PROGRESS_TARGET=""; ALLOWED_RELIGION="none"; STYLE=""; CAPTIONS="on"
USER_VOICE=""; MUSIC_SOURCE=""; MUSIC_PROMPT=""; CRITIQUE="off"
CRITIQUE_LOOP="off"; CRITIQUE_TARGET_SCORE="8.5"; CRITIQUE_MAX_ROUNDS=3
SCENE_SOURCES=()  # array of "N:/path/to/file" entries; processed before asset gen

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --brief) BRIEF="$2"; shift 2 ;;
    --feedback) FEEDBACK="$2"; shift 2 ;;
    --plan-id) PLAN_ID="$2"; shift 2 ;;
    --scene) SCENE_NUM="$2"; shift 2 ;;
    --length) LENGTH="$2"; shift 2 ;;
    --quality) QUALITY="$2"; shift 2 ;;
    --look) LOOK="$2"; shift 2 ;;
    --style) STYLE="$2"; shift 2 ;;
    --aspects) ASPECTS="$2"; shift 2 ;;
    --brand) BRAND="$2"; shift 2 ;;
    --end-logo) END_LOGO="$2"; shift 2 ;;
    --refs) REFS="$2"; shift 2 ;;
    --ab-hero) AB_HERO="$2"; shift 2 ;;
    --two-stage-prompts) TWO_STAGE="$2"; shift 2 ;;
    --max-cost) MAX_COST="$2"; shift 2 ;;
    --progress-target) PROGRESS_TARGET="$2"; shift 2 ;;
    --allowed-religious-context) ALLOWED_RELIGION="$2"; shift 2 ;;
    --captions) CAPTIONS="$2"; shift 2 ;;
    --voice) USER_VOICE="$2"; shift 2 ;;
    --music-source) MUSIC_SOURCE="$2"; shift 2 ;;
    --music-prompt) MUSIC_PROMPT="$2"; shift 2 ;;
    --critique) CRITIQUE="$2"; shift 2 ;;
    --critique-loop) CRITIQUE_LOOP="$2"; shift 2 ;;
    --critique-target-score) CRITIQUE_TARGET_SCORE="$2"; shift 2 ;;
    --critique-max-rounds) CRITIQUE_MAX_ROUNDS="$2"; shift 2 ;;
    --scene-source) SCENE_SOURCES+=("$2"); shift 2 ;;
    # F11 fix: warn on unknown flags (catch typos like --vocie). Don't error to keep loose-compat.
    --*) echo "WARN: unknown flag '$1' — ignoring (typo?)" >&2; shift; [ $# -gt 0 ] && [[ "$1" != --* ]] && shift ;;
    *) shift ;;
  esac
done

# ───────── Voice resolution ─────────
# Voice ID is required. Resolve in order: --voice flag → $VOICE_ID env → error out.
[ -z "$USER_VOICE" ] && USER_VOICE="${VOICE_ID:-}"
if [ -z "$USER_VOICE" ]; then
  echo "ERROR: voice ID required. Set VOICE_ID env or pass --voice <id>." >&2
  echo "       Browse public voices at https://elevenlabs.io/app/voice-library" >&2
  exit 1
fi

# ───────── Music source defaults ─────────
[ -z "$MUSIC_SOURCE" ] && MUSIC_SOURCE="auto"

# F7 fix: validate numeric flags fail fast with clear error (not arithmetic surprise)
if ! [[ "$CRITIQUE_MAX_ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --critique-max-rounds must be a positive integer, got '$CRITIQUE_MAX_ROUNDS'" >&2; exit 1
fi
if ! [[ "$CRITIQUE_TARGET_SCORE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "ERROR: --critique-target-score must be a positive number, got '$CRITIQUE_TARGET_SCORE'" >&2; exit 1
fi
case "$MUSIC_SOURCE" in
  musiclib|elevenlabs|auto) ;;
  *) echo "ERROR: --music-source must be musiclib|elevenlabs|auto, got '$MUSIC_SOURCE'" >&2; exit 1 ;;
esac
case "$CRITIQUE" in on|off) ;; *) echo "ERROR: --critique must be on|off, got '$CRITIQUE'" >&2; exit 1 ;; esac
case "$CRITIQUE_LOOP" in on|off) ;; *) echo "ERROR: --critique-loop must be on|off, got '$CRITIQUE_LOOP'" >&2; exit 1 ;; esac

# ───────── Defaults from quality ─────────
case "$QUALITY" in
  cheap)   IMG_MODEL="flux-schnell";   VID_MODEL="ltx-2";        TWO_STAGE=${TWO_STAGE:-off}; AB_HERO=${AB_HERO:-off} ;;
  medium)  IMG_MODEL="nano-banana-2";  VID_MODEL="ltx-2";        TWO_STAGE=${TWO_STAGE:-off}; AB_HERO=${AB_HERO:-off} ;;
  premium) IMG_MODEL="nano-banana-2";  VID_MODEL="grok-imagine"; TWO_STAGE=${TWO_STAGE:-on};  AB_HERO=${AB_HERO:-on}  ;;
  ultra)   IMG_MODEL="nano-banana-2";  VID_MODEL="grok-imagine"; TWO_STAGE=${TWO_STAGE:-on};  AB_HERO=${AB_HERO:-on}  ;;
  *) echo "ERROR: --quality must be cheap|medium|premium|ultra" >&2; exit 1 ;;
esac

# Default look from style if not set
[ -z "$LOOK" ] && LOOK="$STYLE"
[ -z "$LOOK" ] && LOOK="classic"
[ -z "$STYLE" ] && STYLE="classic"

# ───────── Env validation ─────────
[ -z "$GEMINI_API_KEY" ] && { echo "ERROR: GEMINI_API_KEY not set" >&2; exit 1; }
[ -z "$ELEVENLABS_API_KEY" ] && { echo "ERROR: ELEVENLABS_API_KEY not set" >&2; exit 1; }

# ───────── Paths ─────────
PLAN_DIR=/tmp/ai-video-plans
mkdir -p "$PLAN_DIR"
ASSETS_BASE=/home/node/.openclaw/workspace/scripts/assets
FONTS_DIR="$ASSETS_BASE/fonts"
LIB="$ASSETS_BASE/prompt-library.json"
[ ! -f "$LIB" ] && { echo "ERROR: prompt library not found at $LIB" >&2; exit 1; }

# ───────── Brand presets ─────────
# Brand-specific end-logos and religious-context overrides can be added here.
# Use --end-logo <path> and --allowed-religious-context <ctx> for explicit control.

# ───────── Helper: send progress to WhatsApp via openclaw ─────────
send_progress() {
  local msg="$1"
  [ -z "$PROGRESS_TARGET" ] && return 0
  command -v openclaw >/dev/null 2>&1 || return 0
  openclaw message send --channel whatsapp --target "$PROGRESS_TARGET" -m "$msg" >/dev/null 2>&1 || true
}

# ───────── Helper: Gemini call with file response_mime_type=json ─────────
gemini_json() {
  local prompt_file="$1"  # path to file containing the prompt body json
  local model="${2:-gemini-2.5-flash}"
  curl -sS -X POST "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" --data-binary "@$prompt_file"
}

# ───────── Helper: derive style colors (palette per look, falling back to style) ─────────
PALETTE_KEY="$LOOK"
[ -z "$PALETTE_KEY" ] && PALETTE_KEY="$STYLE"
case "$PALETTE_KEY" in
  modern)      BG="#0c1424"; ACC="#3da9fc"; FG="#ffffff"; GRAD="linear-gradient(135deg,#3da9fc,#00d4ff)" ;;
  medical)     BG="#f5f9ff"; ACC="#0a7ea4"; FG="#0a1726"; GRAD="linear-gradient(135deg,#0a7ea4,#3da9fc)" ;;
  tech)        BG="#0a0e1a"; ACC="#7c5cff"; FG="#ffffff"; GRAD="linear-gradient(135deg,#7c5cff,#22d3ee)" ;;
  warm)        BG="#1a1108"; ACC="#ffaa55"; FG="#fff8e8"; GRAD="linear-gradient(135deg,#ffaa55,#ff7a3d)" ;;
  neon)        BG="#0a0a1e"; ACC="#00ffe1"; FG="#ffffff"; GRAD="linear-gradient(180deg,#00ffe1,#8b5cf6)" ;;
  minimal)     BG="#fafaf7"; ACC="#111827"; FG="#111827"; GRAD="linear-gradient(180deg,#111827,#374151)" ;;
  luxury)      BG="#0a0805"; ACC="#cba76b"; FG="#fffaf0"; GRAD="linear-gradient(180deg,#fff7e6,#cba76b)" ;;
  documentary) BG="#1a1a1a"; ACC="#e8c87a"; FG="#fafafa"; GRAD="linear-gradient(135deg,#e8c87a,#a8854a)" ;;
  classic|*)   BG="#05060c"; ACC="#f5c77a"; FG="#ffffff"; GRAD="linear-gradient(180deg,#fff7e6,#f5c77a)" ;;
esac
hex_to_ass_bgr() { local h="${1#\#}"; echo "&H00${h:4:2}${h:2:2}${h:0:2}"; }
ACC_ASS=$(hex_to_ass_bgr "$ACC")

# ───────── MODE: PLAN ─────────
do_plan() {
  [ -z "$BRIEF" ] && { echo "ERROR: --brief required for plan mode" >&2; exit 1; }
  PLAN_ID="p_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  PLAN_FILE="$PLAN_DIR/${PLAN_ID}.json"
  echo "[plan/1] director writing script + scene outline..." >&2

  # Build director prompt body
  local DIR_PROMPT
  DIR_PROMPT=$(python3 - "$BRIEF" "$LENGTH" "$QUALITY" "$LOOK" "$STYLE" "$BRAND" "$ALLOWED_RELIGION" "$LIB" <<'PYEOF'
import json, sys
brief, length, quality, look, style, brand, religion, libpath = sys.argv[1:9]
lib = json.load(open(libpath, encoding="utf-8"))
relmode = lib["religious_safety"]["modes"][religion]
director_instr = relmode["director_instruction"]
allowed = ", ".join(relmode.get("allowed_terms", [])) or "none specified"
forbidden = ", ".join(relmode["forbidden_terms"])
scene_count_target = max(3, min(8, int(length) // 5 + 1))

prompt = f"""You are a senior creative director. Plan a Hebrew promo/campaign video.

**Brief (Hebrew):** {brief}
**Target length:** {length} seconds (±5)
**Quality tier:** {quality}
**Look/style:** {look}
**Brand:** {brand or "(none — secular brand)"}

**HARD SAFETY CONSTRAINT:** {director_instr}
Forbidden in any scene: {forbidden}
Allowed religious imagery (only if brand context fits): {allowed}

**Output a single JSON object with these exact keys:**
- title: short Hebrew title (1-4 words)
- subtitle: short Hebrew tagline (3-7 words)
- outro: short Hebrew CTA or URL string (1-6 words)
- narration: full Hebrew narration text. 2-5 sentences. Match {length}s of natural Hebrew speech (~14 words per 5s). Compelling, non-generic, not banal.
- music_mood: one or two musiclib mood tags from this list: cinematic,dramatic,emotional,inspirational,uplifting,corporate,tense,reflective,triumphant,festive
- scenes: array of {scene_count_target} scene objects. Each scene:
  - i: 1-based index
  - type: "video" or "image" (max 50% videos for cost; pick "image" unless motion is essential)
  - duration: seconds (3-6)
  - intent: one of hook|hero|build|reveal|cta
  - story_beat: short Hebrew description (5-15 words) of what this scene communicates
  - subject: vivid English description of the visual subject (people, objects, setting). Be SPECIFIC — names, colors, actions, environment. NO Christian/Muslim symbols.
  - ken_burns: for image scenes only — one of zoom_in_center|zoom_out_center|pan_left|pan_right|pan_up. null for videos.
- title_card_inserts: array (MAX 1 ITEM, can be empty). If included: {{"before_scene": <i>, "text": "<2-4 Hebrew words>"}}
- overlays: array (max one per ~3 scenes). Each: {{"scene": <i>, "text": "<3-7 Hebrew words>", "position": "top-right|top-left|bottom-center", "in_at": <sec from scene start>, "duration": <sec>, "animation": "slide_fade|pop|reveal"}}
- motion_graphics: array of professional marketing motion-design overlays (~2-4 total across the whole video, NOT every scene). These are FULL professional graphics, not tiny corner badges. Each is one of these types:
  * {{"scene": <i>, "type": "hero_stat", "value": "<big number, e.g. 72%, 5★, +200>", "label": "<2-5 Hebrew words underneath>", "in_at": <sec>, "duration": 2.5}} — fills the screen with a HUGE number (~380px) over a darkened scene. Use for impactful single statistics (intro hooks, climax reveals).
  * {{"scene": <i>, "type": "metric_bar", "value": "<number e.g. 47>", "prefix": "<optional, e.g. +>", "suffix": "<optional, e.g. %>", "label": "<2-4 Hebrew words>", "in_at": <sec>, "duration": 3.0}} — large stat with bar chart in a bordered box, on top of scene. Use for results/proof numbers.
  * {{"scene": <i>, "type": "bottom_panel", "metrics": [{{"label":"<word>","value":"<short>"}}, {{"label":"<word>","value":"<short>"}}], "in_at": <sec>, "duration": 3.0}} — full-width bottom panel with 2-3 metrics. Use to show simultaneous KPIs.
  * {{"scene": <i>, "type": "mockup_ui", "title": "<UI section name, 1-3 Hebrew words>", "lines": ["<line1>", "<line2>", "<line3>"], "in_at": <sec>, "duration": 4.0}} — UI mockup card on the side simulating a product screen (e.g. transcript, dashboard). Use to show product-in-action.
  * {{"scene": <i>, "type": "brand_card", "name": "<brand or final word>", "tagline": "<Hebrew tagline>", "in_at": <sec>, "duration": 2.5}} — full-screen brand reveal with bordered logo box and tagline. Use ONLY on the final scene as a closer.
  Pick types that genuinely amplify the scene's message. Prefer hero_stat for hooks, metric_bar for proof numbers, bottom_panel for KPI summaries, mockup_ui for product visualization, brand_card for the closing scene only.

Total cumulative scene durations should approximately equal {length} seconds.

Output ONLY the JSON, no markdown fences, no prose."""
print(prompt)
PYEOF
)

  # Save prompt + body to temp
  local TMPDIR; TMPDIR=$(mktemp -d)
  python3 - "$DIR_PROMPT" "$TMPDIR/dir-body.json" <<'PYEOF'
import json, sys
prompt, out = sys.argv[1:3]
body = {
  "contents": [{"parts": [{"text": prompt}]}],
  "generationConfig": {"response_mime_type": "application/json", "temperature": 0.7}
}
json.dump(body, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF

  local DIR_RESP
  DIR_RESP=$(gemini_json "$TMPDIR/dir-body.json" "gemini-2.5-flash")
  local DIR_JSON
  DIR_JSON=$(echo "$DIR_RESP" | jq -r '.candidates[0].content.parts[0].text // empty')
  [ -z "$DIR_JSON" ] && { echo "ERROR: director returned empty" >&2; echo "$DIR_RESP" >&2; rm -rf "$TMPDIR"; exit 1; }
  echo "$DIR_JSON" > "$TMPDIR/director.json"

  # Validate director JSON parses
  jq -e '.title and .narration and .scenes' "$TMPDIR/director.json" >/dev/null 2>&1 || {
    echo "ERROR: director JSON malformed" >&2; cat "$TMPDIR/director.json" >&2; rm -rf "$TMPDIR"; exit 1
  }

  echo "[plan/2] prompt engineer formatting visual prompts per model..." >&2

  # Run prompt engineer per scene — single Gemini call processing all scenes batch
  python3 - "$TMPDIR/director.json" "$LIB" "$IMG_MODEL" "$VID_MODEL" "$LOOK" "$ALLOWED_RELIGION" "$BRAND" "$TMPDIR/pe-body.json" <<'PYEOF'
import json, sys
djson, libpath, img_model, vid_model, look, religion, brand, out = sys.argv[1:9]
director = json.load(open(djson, encoding="utf-8"))
lib = json.load(open(libpath, encoding="utf-8"))
look_desc = lib["looks"].get(look, lib["looks"]["classic"])
relmode = lib["religious_safety"]["modes"][religion]
prompt_inj = relmode["prompt_injection"]
neg_default = lib["negative_prompts"]["default"]
neg_relig = lib["negative_prompts"]["religious_strict"]
scenes = director["scenes"]

formatter_msgs = []
for s in scenes:
  model = vid_model if s["type"] == "video" else img_model
  fmt = lib["model_formatters"].get(model, lib["model_formatters"]["nano-banana-2"])
  formatter_msgs.append({
    "i": s["i"],
    "type": s["type"],
    "model": model,
    "duration": s["duration"],
    "intent": s["intent"],
    "subject_hint": s["subject"],
    "format_hint": fmt["system_hint"],
    "max_chars": fmt["max_chars"]
  })

intent_descriptors = lib["scene_intent_descriptors"]

prompt = f"""You are an expert AI image/video prompt engineer. Take these scene briefs and produce EXCELLENT visual prompts for the specified models.

LOOK descriptors to weave in: "{look_desc}"
SAFETY: {prompt_inj}
Brand context: {brand or "secular professional"}

For each scene, produce:
- prompt_final: a vivid English prompt within max_chars, following the format_hint structure, weaving look descriptors naturally
- negative_prompt: combine "{neg_default}" with relevant safety terms from "{neg_relig}"

Intent style guide:
{json.dumps(intent_descriptors, indent=2)}

Input scenes:
{json.dumps(formatter_msgs, ensure_ascii=False, indent=2)}

Output ONLY a JSON object with key "scenes" — array of {{i, prompt_final, negative_prompt}}. No markdown, no prose."""

body = {
  "contents":[{"parts":[{"text":prompt}]}],
  "generationConfig":{"response_mime_type":"application/json","temperature":0.5}
}
json.dump(body, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF

  local PE_RESP
  PE_RESP=$(gemini_json "$TMPDIR/pe-body.json" "gemini-2.5-flash")
  local PE_JSON
  PE_JSON=$(echo "$PE_RESP" | jq -r '.candidates[0].content.parts[0].text // empty')
  [ -z "$PE_JSON" ] && { echo "ERROR: prompt engineer returned empty" >&2; echo "$PE_RESP" >&2; rm -rf "$TMPDIR"; exit 1; }
  echo "$PE_JSON" > "$TMPDIR/pe.json"

  echo "[plan/3] assembling final plan..." >&2
  python3 - "$TMPDIR/director.json" "$TMPDIR/pe.json" "$PLAN_FILE" "$PLAN_ID" "$BRIEF" "$LENGTH" "$QUALITY" "$LOOK" "$STYLE" "$BRAND" "$ASPECTS" "$IMG_MODEL" "$VID_MODEL" "$ALLOWED_RELIGION" "$MAX_COST" "$AB_HERO" "$TWO_STAGE" "$END_LOGO" "$PROGRESS_TARGET" <<'PYEOF'
import json, sys, datetime
djson, pejson, out, plan_id, brief, length, quality, look, style, brand, aspects, img_model, vid_model, religion, max_cost, ab_hero, two_stage, end_logo, prog_target = sys.argv[1:20]
director = json.load(open(djson, encoding="utf-8"))
pe = json.load(open(pejson, encoding="utf-8"))
pe_by_i = {s["i"]: s for s in pe["scenes"]}

# Cost lookup
COST = {
  "grok-imagine":  lambda dur: 1.10 * (dur/5.0),
  "ltx-2":         lambda dur: 0.07 * (dur/5.0),
  "nano-banana-2": lambda _: 0.039,
  "imagen-3.0":    lambda _: 0.04,
  "flux-pro-1.1":  lambda _: 0.04,
  "flux-schnell":  lambda _: 0.003,
}

scenes_out = []
total = 0.0
for s in director["scenes"]:
  model = vid_model if s["type"] == "video" else img_model
  pe_entry = pe_by_i.get(s["i"], {})
  ab_variants = 2 if (ab_hero == "on" and s["intent"] in ("hook","hero")) else 1
  per = COST.get(model, lambda d:0.05)(s["duration"])
  est = per * ab_variants
  total += est
  scenes_out.append({
    "i": s["i"],
    "type": s["type"],
    "model": model,
    "duration_sec": s["duration"],
    "aspect": aspects.split(",")[0],
    "intent": s["intent"],
    "story_beat": s["story_beat"],
    "subject": s["subject"],
    "prompt_final": pe_entry.get("prompt_final", ""),
    "negative_prompt": pe_entry.get("negative_prompt", ""),
    "ken_burns": s.get("ken_burns"),
    "ab_variants": ab_variants,
    "estimated_cost": round(est, 4),
    "actual_cost": None,
    "asset_path": None,
    "status": "pending",
    "safety_retries": 0
  })
total += 0.01  # narration ~ELabs
total += 0.005  # director call
total += 0.003 * len(scenes_out)  # PE per scene
total += 0.001 * len(scenes_out)  # safety audit per scene

plan = {
  "plan_id": plan_id,
  "version": "1.5",
  "brief": brief,
  "length_sec": int(length),
  "quality": quality,
  "look": look,
  "style": style,
  "brand": brand or None,
  "aspects": aspects.split(","),
  "title": director.get("title",""),
  "subtitle": director.get("subtitle",""),
  "outro": director.get("outro",""),
  "narration": director.get("narration",""),
  "music_mood": director.get("music_mood","cinematic,emotional"),
  "scenes": scenes_out,
  "title_card_inserts": (director.get("title_card_inserts") or [])[:1],  # hard cap 1
  "overlays": director.get("overlays") or [],
  "motion_graphics": director.get("motion_graphics") or [],
  "religious_context": religion,
  "ab_hero": ab_hero,
  "two_stage_prompts": two_stage,
  "end_logo": end_logo or None,
  "progress_target": prog_target or None,
  "estimated_cost_usd": round(total, 4),
  "actual_cost_usd": None,
  "max_cost_usd": float(max_cost),
  "status": "awaiting_approval",
  "created_at": datetime.datetime.utcnow().isoformat() + "Z",
  "approved_at": None,
  "produced_at": None
}
json.dump(plan, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

# Print plain Hebrew preview to stdout
print("───── תוכנית הסרטון ─────")
print(f"PLAN_ID: {plan_id}")
print(f"כותרת: {plan['title']}")
print(f"תת-כותרת: {plan['subtitle']}")
print(f"קריינות: {plan['narration']}")
print(f"סצנות ({len(scenes_out)}):")
for s in scenes_out:
  print(f"  {s['i']}. ({s['type']}, {s['duration_sec']}s, {s['intent']}) — {s['story_beat']}")
if plan["title_card_inserts"]:
  tc = plan["title_card_inserts"][0]
  print(f"כרטיס מעבר לפני סצנה {tc.get('before_scene')}: {tc.get('text')}")
if plan["overlays"]:
  for o in plan["overlays"]:
    print(f"כיתוב על סצנה {o.get('scene')}: {o.get('text')} ({o.get('position')})")
if plan.get("motion_graphics"):
  print("גרפיקה דינמית:")
  for mg in plan["motion_graphics"]:
    t = mg.get("type")
    if t == "hero_stat":
      print(f"  סצנה {mg['scene']}: HERO {mg.get('value')} — {mg.get('label')}")
    elif t == "metric_bar":
      pre = mg.get('prefix','') or ''
      suf = mg.get('suffix','') or ''
      print(f"  סצנה {mg['scene']}: סטטיסטיקה+bar {pre}{mg.get('value')}{suf} — {mg.get('label')}")
    elif t == "bottom_panel":
      m = mg.get('metrics', [])
      print(f"  סצנה {mg['scene']}: פאנל תחתון " + " | ".join(f"{x.get('label')}: {x.get('value')}" for x in m))
    elif t == "mockup_ui":
      print(f"  סצנה {mg['scene']}: mockup UI \"{mg.get('title')}\" ({len(mg.get('lines',[]))} שורות)")
    elif t == "brand_card":
      print(f"  סצנה {mg['scene']}: BRAND CARD {mg.get('name')} — {mg.get('tagline')}")
    else:
      print(f"  סצנה {mg['scene']}: {t} (legacy, may be skipped)")
print(f"מוזיקה: {plan['music_mood']}")
print(f"עלות מוערכת: ${plan['estimated_cost_usd']}")
print(f"סטטוס: ממתין לאישור")
print(f"לאישור: --mode produce --plan-id {plan_id}")
print(f"לתיקון: --mode revise --plan-id {plan_id} --feedback \"...\"")
PYEOF

  rm -rf "$TMPDIR"
}

# ───────── MODE: REVISE ─────────
do_revise() {
  [ -z "$PLAN_ID" ] && { echo "ERROR: --plan-id required" >&2; exit 1; }
  [ -z "$FEEDBACK" ] && { echo "ERROR: --feedback required" >&2; exit 1; }
  local PLAN_FILE="$PLAN_DIR/${PLAN_ID}.json"
  [ ! -f "$PLAN_FILE" ] && { echo "ERROR: plan $PLAN_ID not found" >&2; exit 1; }
  echo "[revise] applying feedback to plan $PLAN_ID..." >&2

  # Re-derive original brief from plan + feedback, re-run director
  BRIEF=$(jq -r '.brief' "$PLAN_FILE")
  LENGTH=$(jq -r '.length_sec' "$PLAN_FILE")
  QUALITY=$(jq -r '.quality' "$PLAN_FILE")
  LOOK=$(jq -r '.look' "$PLAN_FILE")
  STYLE=$(jq -r '.style' "$PLAN_FILE")
  BRAND=$(jq -r '.brand // ""' "$PLAN_FILE")
  ASPECTS=$(jq -r '.aspects | join(",")' "$PLAN_FILE")
  ALLOWED_RELIGION=$(jq -r '.religious_context' "$PLAN_FILE")
  END_LOGO=$(jq -r '.end_logo // ""' "$PLAN_FILE")
  PROGRESS_TARGET=$(jq -r '.progress_target // ""' "$PLAN_FILE")
  MAX_COST=$(jq -r '.max_cost_usd' "$PLAN_FILE")
  AB_HERO=$(jq -r '.ab_hero' "$PLAN_FILE")
  TWO_STAGE=$(jq -r '.two_stage_prompts' "$PLAN_FILE")
  case "$QUALITY" in
    cheap)   IMG_MODEL="flux-schnell";   VID_MODEL="ltx-2" ;;
    medium)  IMG_MODEL="nano-banana-2";  VID_MODEL="ltx-2" ;;
    premium|ultra) IMG_MODEL="nano-banana-2";  VID_MODEL="grok-imagine" ;;
  esac

  # Augment brief with feedback for re-planning
  BRIEF="${BRIEF}

תיקונים מהמשתמש: ${FEEDBACK}"
  do_plan
}

# ───────── MODE: PRODUCE ─────────
do_produce() {
  [ -z "$PLAN_ID" ] && { echo "ERROR: --plan-id required" >&2; exit 1; }
  local PLAN_FILE="$PLAN_DIR/${PLAN_ID}.json"
  [ ! -f "$PLAN_FILE" ] && { echo "ERROR: plan $PLAN_ID not found" >&2; exit 1; }
  local STATUS; STATUS=$(jq -r '.status' "$PLAN_FILE")
  if [ "$STATUS" = "produced" ]; then
    echo "INFO: plan already produced, re-producing..." >&2
  fi
  local EST_COST; EST_COST=$(jq -r '.estimated_cost_usd' "$PLAN_FILE")
  local MAX_C; MAX_C=$(jq -r '.max_cost_usd' "$PLAN_FILE")
  if awk "BEGIN{exit !($EST_COST > $MAX_C)}"; then
    echo "ERROR: estimated cost \$$EST_COST exceeds max \$$MAX_C — abort. Use --max-cost N to override." >&2
    exit 1
  fi
  jq '.status = "approved" | .approved_at = (now | todate)' "$PLAN_FILE" > "$PLAN_FILE.tmp" && mv "$PLAN_FILE.tmp" "$PLAN_FILE"
  PROGRESS_TARGET=$(jq -r '.progress_target // ""' "$PLAN_FILE")
  send_progress "🎬 מתחיל הפקה (סטטוס: 0/8)"

  # ───────── v1.6: critique loop wrapper ─────────
  # If --critique-loop=on, run produce → critique → patch-plan → re-produce until target or max rounds.
  local FINAL_OUT=""
  local CRITIQUE_OUT="/tmp/ai-video-critique-${PLAN_ID}.json"
  local PATCH_LOG="/tmp/ai-video-patch-${PLAN_ID}.log"
  local WORK_DIR_BASE="/tmp/ai-video-${PLAN_ID}"
  local round=1
  while :; do
    if [ "$CRITIQUE_LOOP" = "on" ] && [ "$round" -gt 1 ]; then
      send_progress "🔁 סבב ${round}/${CRITIQUE_MAX_ROUNDS} (אחרי תיקון Gemini)"
      echo "[critique-loop] round ${round}: re-running produce after patches..." >&2
    fi
    # Ensure critique runs on every loop iteration when looping
    if [ "$CRITIQUE_LOOP" = "on" ]; then CRITIQUE="on"; fi
    # F-NEW-1 fix: don't capture stdout via $() — set -e may not propagate failures through command substitution.
    # Run produce_pipeline directly; failures abort via set -e at the top.
    # produce_pipeline echoes the path to stdout; redirect it to a tmp file since we know the deterministic path.
    produce_pipeline "$PLAN_FILE" > "${WORK_DIR_BASE}-stdout.log"
    FINAL_OUT="/tmp/ai-video-result-${PLAN_ID}.mp4"
    if [ ! -s "$FINAL_OUT" ]; then
      echo "[critique-loop] expected $FINAL_OUT not produced — aborting" >&2
      exit 1
    fi
    # Decide whether to loop
    if [ "$CRITIQUE_LOOP" != "on" ]; then break; fi
    if [ "$round" -ge "$CRITIQUE_MAX_ROUNDS" ]; then
      echo "[critique-loop] reached max rounds ($CRITIQUE_MAX_ROUNDS), stopping" >&2
      break
    fi
    if [ ! -f "$CRITIQUE_OUT" ]; then
      echo "[critique-loop] no critique output — stopping" >&2
      break
    fi
    local CUR_SCORE; CUR_SCORE=$(jq -r '.overall_score // 0' "$CRITIQUE_OUT")
    local READY; READY=$(jq -r '.ready_to_ship // false' "$CRITIQUE_OUT")
    if [ "$READY" = "true" ]; then
      echo "[critique-loop] ready_to_ship=true, stopping" >&2
      break
    fi
    if awk "BEGIN{exit !($CUR_SCORE >= $CRITIQUE_TARGET_SCORE)}"; then
      echo "[critique-loop] score $CUR_SCORE >= target $CRITIQUE_TARGET_SCORE, stopping" >&2
      break
    fi
    # Attempt patch-plan
    local PATCH_HELPER="/home/node/.openclaw/workspace/scripts/patch-plan.cjs"
    if [ ! -f "$PATCH_HELPER" ]; then
      echo "[critique-loop] patch helper missing at $PATCH_HELPER — stopping" >&2
      break
    fi
    local PLAN_NEW="${PLAN_FILE}.next"
    local PATCH_ERRLOG="${PATCH_LOG}.err"
    if ! NODE_PATH=/app/node_modules node "$PATCH_HELPER" "$PLAN_FILE" "$CRITIQUE_OUT" "$PLAN_NEW" > "$PATCH_LOG" 2> "$PATCH_ERRLOG"; then
      echo "[critique-loop] patch-plan applied 0 patches — stopping" >&2
      [ -s "$PATCH_ERRLOG" ] && cat "$PATCH_ERRLOG" >&2 || true
      break
    fi
    mv "$PLAN_NEW" "$PLAN_FILE"
    local APPLIED; APPLIED=$(jq -r '.total_applied // "?"' "$PATCH_LOG" 2>/dev/null || echo "?")
    echo "[critique-loop] round ${round} applied ${APPLIED} patches, looping..." >&2
    send_progress "✏️ הוחלו ${APPLIED} תיקונים, מרכיב מחדש..."
    round=$((round + 1))
  done
  echo "$FINAL_OUT"
}

# ───────── MODE: REGEN-SCENE ─────────
do_regen_scene() {
  [ -z "$PLAN_ID" ] && { echo "ERROR: --plan-id required" >&2; exit 1; }
  [ -z "$SCENE_NUM" ] && { echo "ERROR: --scene N required" >&2; exit 1; }
  local PLAN_FILE="$PLAN_DIR/${PLAN_ID}.json"
  [ ! -f "$PLAN_FILE" ] && { echo "ERROR: plan $PLAN_ID not found" >&2; exit 1; }
  echo "[regen-scene] regenerating scene $SCENE_NUM in plan $PLAN_ID..." >&2
  PROGRESS_TARGET=$(jq -r '.progress_target // ""' "$PLAN_FILE")

  # Reset that scene's status + asset path
  jq --arg n "$SCENE_NUM" '(.scenes[] | select(.i == ($n|tonumber))) |= (.status="pending" | .asset_path=null | .actual_cost=null | .safety_retries=0)' "$PLAN_FILE" > "$PLAN_FILE.tmp" && mv "$PLAN_FILE.tmp" "$PLAN_FILE"

  # Regenerate just that scene asset
  local ASSETS_DIR="/tmp/ai-video-${PLAN_ID}-assets"
  mkdir -p "$ASSETS_DIR"
  generate_scene_asset "$PLAN_FILE" "$SCENE_NUM" "$ASSETS_DIR"

  # Re-run pipeline composition only
  produce_pipeline "$PLAN_FILE"
}

# ───────── PRODUCE: full pipeline ─────────
produce_pipeline() {
  local PLAN_FILE="$1"
  local WORK="/tmp/ai-video-${PLAN_ID}"
  local ASSETS_DIR="${WORK}-assets"
  mkdir -p "$WORK" "$ASSETS_DIR"

  send_progress "🎤 1/8 — יוצר קריינות..."
  echo "[produce/1] narration..." >&2
  local NARRATION; NARRATION=$(jq -r '.narration' "$PLAN_FILE")
  # USER_VOICE was validated non-empty at startup
  local VOICE_ID="$USER_VOICE"
  echo "[produce/1] voice=${VOICE_ID}" >&2
  curl -sS -X POST "https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}?output_format=mp3_44100_128" \
    -H "xi-api-key: ${ELEVENLABS_API_KEY}" -H "Content-Type: application/json" -H "accept: audio/mpeg" \
    -d "$(jq -n --arg t "$NARRATION" '{text:$t, model_id:"eleven_v3", voice_settings:{stability:0.5, similarity_boost:0.85, style:0.3, use_speaker_boost:true}}')" \
    -o "$WORK/narration.mp3"
  [ ! -s "$WORK/narration.mp3" ] && { echo "ERROR: narration empty" >&2; exit 1; }
  local NARR_DUR; NARR_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$WORK/narration.mp3")

  # v1.6: process --scene-source overrides before AI gen
  if [ "${#SCENE_SOURCES[@]}" -gt 0 ]; then
    echo "[produce/1.5] applying ${#SCENE_SOURCES[@]} user scene-source override(s)..." >&2
    local SCENE_COUNT_CHECK; SCENE_COUNT_CHECK=$(jq '.scenes | length' "$PLAN_FILE")
    for entry in "${SCENE_SOURCES[@]}"; do
      local sn="${entry%%:*}"
      local sp="${entry#*:}"
      if [ -z "$sn" ] || [ -z "$sp" ] || [ "$sn" = "$sp" ]; then
        echo "  WARN: bad --scene-source '$entry' (expected N:path) — skipping" >&2; continue
      fi
      # F1 fix: validate sn is a positive integer (jq --argjson would crash otherwise)
      if ! [[ "$sn" =~ ^[1-9][0-9]*$ ]]; then
        echo "  ERROR: --scene-source: scene number must be a positive integer, got '$sn' — skipping" >&2; continue
      fi
      # F3 fix: validate scene index exists in plan
      if [ "$sn" -gt "$SCENE_COUNT_CHECK" ]; then
        echo "  ERROR: --scene-source: scene $sn not in plan (only $SCENE_COUNT_CHECK scenes) — skipping" >&2; continue
      fi
      if [ ! -f "$sp" ]; then
        echo "  ERROR: --scene-source $sn: file not found: $sp — skipping" >&2; continue
      fi
      local ext="${sp##*.}"
      ext="${ext,,}"
      local stype=""
      case "$ext" in
        mp4|mov|webm|m4v|avi|mkv) stype="video" ;;
        jpg|jpeg|png|webp|gif|bmp) stype="image" ;;
        *) echo "  ERROR: --scene-source $sn: unsupported ext .$ext — skipping" >&2; continue ;;
      esac
      local dest="$ASSETS_DIR/scene_${sn}_user.${ext}"
      # F2 fix: error-check cp
      if ! cp "$sp" "$dest" 2>&1; then
        echo "  ERROR: --scene-source $sn: failed to copy '$sp' → '$dest' — skipping" >&2; continue
      fi
      jq --argjson n "$sn" --arg p "$dest" --arg t "$stype" '
        (.scenes[] | select(.i == $n)).asset_path = $p
        | (.scenes[] | select(.i == $n)).type = $t
        | (.scenes[] | select(.i == $n)).status = "done"
      ' "$PLAN_FILE" > "$PLAN_FILE.tmp" && mv "$PLAN_FILE.tmp" "$PLAN_FILE"
      echo "  scene $sn ← $sp ($stype)" >&2
    done
  fi

  send_progress "🎨 2/8 — מייצר ויזואלים..."
  echo "[produce/2] generating scene assets..." >&2
  local SCENE_COUNT; SCENE_COUNT=$(jq '.scenes | length' "$PLAN_FILE")
  # F6 fix: fail fast on empty plan rather than producing a broken video
  if [ "$SCENE_COUNT" -lt 1 ]; then
    echo "ERROR: plan has no scenes — Director output was empty. Re-run plan or revise the brief." >&2
    exit 1
  fi
  for i in $(seq 1 "$SCENE_COUNT"); do
    local STATUS; STATUS=$(jq -r --arg n "$i" '.scenes[] | select(.i == ($n|tonumber)) | .status' "$PLAN_FILE")
    if [ "$STATUS" = "done" ]; then
      echo "  scene $i: cached" >&2
      continue
    fi
    generate_scene_asset "$PLAN_FILE" "$i" "$ASSETS_DIR"
    send_progress "✅ סצנה $i/$SCENE_COUNT הושלמה"
  done

  send_progress "✂️ 3/8 — מנרמל קליפים..."
  echo "[produce/3] normalizing clips..." >&2
  local FIRST_ASPECT; FIRST_ASPECT=$(jq -r '.aspects[0]' "$PLAN_FILE")
  local W H
  case "$FIRST_ASPECT" in
    "9:16") W=1080; H=1920 ;;
    "1:1")  W=1080; H=1080 ;;
    *)      W=1920; H=1080 ;;
  esac
  > "$WORK/list.txt"
  for i in $(seq 1 "$SCENE_COUNT"); do
    local SCENE_JSON; SCENE_JSON=$(jq --arg n "$i" '.scenes[] | select(.i == ($n|tonumber))' "$PLAN_FILE")
    local SRC; SRC=$(echo "$SCENE_JSON" | jq -r '.asset_path // ""')
    local TYPE; TYPE=$(echo "$SCENE_JSON" | jq -r '.type')
    local DUR;  DUR=$(echo "$SCENE_JSON" | jq -r '.duration_sec')
    local KB;   KB=$(echo "$SCENE_JSON" | jq -r '.ken_burns // ""')
    local OUT_CLIP="$WORK/clip_${i}.mp4"
    if [ ! -s "$SRC" ]; then
      echo "  WARN: scene $i missing asset, skipping" >&2; continue
    fi
    if [ "$TYPE" = "image" ]; then
      # Apply Ken Burns via zoompan
      local FRAMES; FRAMES=$(awk "BEGIN{printf \"%d\", $DUR*30}")
      local KB_FILTER
      case "$KB" in
        zoom_in_center)  KB_FILTER="scale=${W}*4:${H}*4,zoompan=z='min(zoom+0.0010,1.4)':d=${FRAMES}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${W}x${H}:fps=30" ;;
        zoom_out_center) KB_FILTER="scale=${W}*4:${H}*4,zoompan=z='max(1.4-zoom*0,1.4-on*0.0010)':d=${FRAMES}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${W}x${H}:fps=30" ;;
        pan_left)        KB_FILTER="scale=${W}*2:${H}*2,zoompan=z='1.2':d=${FRAMES}:x='if(eq(on,0),iw-(iw/zoom),x-iw*0.4/${FRAMES})':y='ih/2-(ih/zoom/2)':s=${W}x${H}:fps=30" ;;
        pan_right)       KB_FILTER="scale=${W}*2:${H}*2,zoompan=z='1.2':d=${FRAMES}:x='if(eq(on,0),0,x+iw*0.4/${FRAMES})':y='ih/2-(ih/zoom/2)':s=${W}x${H}:fps=30" ;;
        pan_up)          KB_FILTER="scale=${W}*2:${H}*2,zoompan=z='1.2':d=${FRAMES}:x='iw/2-(iw/zoom/2)':y='if(eq(on,0),ih-(ih/zoom),y-ih*0.4/${FRAMES})':s=${W}x${H}:fps=30" ;;
        *)               KB_FILTER="scale=${W}*4:${H}*4,zoompan=z='min(zoom+0.0006,1.2)':d=${FRAMES}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${W}x${H}:fps=30" ;;
      esac
      ffmpeg -y -loop 1 -t "$DUR" -i "$SRC" \
        -f lavfi -t "$DUR" -i anullsrc=r=48000:cl=stereo \
        -filter_complex "[0:v]${KB_FILTER},setsar=1[v]" \
        -map "[v]" -map 1:a \
        -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 128k -ar 48000 -ac 2 -shortest \
        "$OUT_CLIP" -loglevel error
    else
      # Video — normalize to target W×H @ 30fps WITH SILENT AUDIO (we add narration+music later as one clean stream)
      ffmpeg -y -i "$SRC" -f lavfi -t "$DUR" -i anullsrc=r=48000:cl=stereo \
        -filter_complex "[0:v]scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:black,fps=30,setsar=1[v]" \
        -map "[v]" -map 1:a -t "$DUR" \
        -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p \
        -c:a aac -b:a 128k -ar 48000 -ac 2 \
        "$OUT_CLIP" -loglevel error
    fi
    [ ! -s "$OUT_CLIP" ] && { echo "ERROR: clip $i normalization failed" >&2; exit 1; }
    # Apply motion graphics (badges, lower-thirds, stats, checkmark lists) if Director proposed any for this scene
    apply_motion_graphics "$PLAN_FILE" "$i" "$OUT_CLIP" "$WORK/clip_${i}_mg.mp4" "$W" "$H"
    if [ -s "$WORK/clip_${i}_mg.mp4" ]; then
      mv "$WORK/clip_${i}_mg.mp4" "$OUT_CLIP"
    fi
    echo "file 'clip_${i}.mp4'" >> "$WORK/list.txt"
  done
  ffmpeg -y -f concat -safe 0 -i "$WORK/list.txt" -c copy "$WORK/body-raw.mp4" -loglevel error

  send_progress "📝 4/8 — תמלול ובניית כתוביות..."
  echo "[produce/4] transcribe + ASS captions..." >&2
  local TRANSCRIBE_OK=0
  if [ "$CAPTIONS" = "on" ]; then
    python3 - "$WORK/narration.mp3" "$NARRATION" "$WORK/trans-body.json" <<'PYPOST'
import json, base64, sys
audio_path, narration, out_path = sys.argv[1:4]
audio = base64.b64encode(open(audio_path, "rb").read()).decode()
prompt = f"""Transcribe this Hebrew audio into SRT subtitle format.

CRITICAL RULES FOR TIMING:
- Listen carefully to when each word is spoken — timestamps must match the actual audio precisely
- Each subtitle entry must start exactly when the speaker begins that phrase and end when they finish
- Silence gaps between sentences should NOT be included in subtitle duration
- Timestamps format: HH:MM:SS,mmm --> HH:MM:SS,mmm (comma for milliseconds, NOT dot)
- Entries must be sequential — each entry starts at or after the previous entry ends
- No overlapping timestamps

RULES FOR TEXT:
- Generate standard SRT format with sequential numbering
- Keep entries short: 3-8 words per entry for Hebrew (right-to-left) subtitle readability
- Hebrew text must use proper niqqud-free spelling as used in modern Hebrew
- Output ONLY the SRT content — no markdown fences, no explanations, no comments

SPELLING REFERENCE — Use the EXACT words and spelling from this original script. The script is the authoritative source for correct spelling:
{narration}"""
body = {
  "contents": [{"parts": [
    {"inlineData": {"mimeType": "audio/mpeg", "data": audio}},
    {"text": prompt}
  ]}],
  "generationConfig": {"temperature": 0.1}
}
json.dump(body, open(out_path, "w", encoding="utf-8"), ensure_ascii=False)
PYPOST
    for TM in gemini-2.5-flash gemini-2.0-flash; do
      local TR; TR=$(curl -sS -X POST "https://generativelanguage.googleapis.com/v1beta/models/${TM}:generateContent?key=${GEMINI_API_KEY}" -H "Content-Type: application/json" --data-binary "@$WORK/trans-body.json")
      local SRT; SRT=$(echo "$TR" | jq -r '.candidates[0].content.parts[0].text // empty' | sed -E 's/^```[a-z]*$//g; s/^```$//g')
      if [ -n "$SRT" ] && echo "$SRT" | grep -q -E '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> '; then
        echo "$SRT" > "$WORK/transcript.srt"
        TRANSCRIBE_OK=1; break
      fi
    done
  fi

  # Build ASS — caption style auto-selected by look (cherry-pick concept from Kevin69007 styles.json)
  # Caption font (libass matches via fontconfig family name).
  # Default: Heebo (free, Google Fonts, supports Hebrew). Override with $CAPTION_FONT_NAME env.
  # Install on host: e.g. `apt install fonts-heebo` or download from Google Fonts.
  local CAPTION_FONT="${CAPTION_FONT_NAME:-Heebo}"
  local CAP_STYLE="bold"
  case "$LOOK" in
    modern|tech)         CAP_STYLE="neon" ;;
    warm|luxury)         CAP_STYLE="hormozi" ;;
    minimal|medical)     CAP_STYLE="minimal" ;;
    *)                   CAP_STYLE="bold" ;;
  esac
  # v1.6: text_style enrichment — font_size_multiplier + position (default bottom-center)
  local FONT_SIZE_MULT; FONT_SIZE_MULT=$(jq -r '.text_style.font_size_multiplier // 1.0' "$PLAN_FILE")
  local TEXT_POS; TEXT_POS=$(jq -r '.text_style.position // "bottom-center"' "$PLAN_FILE")
  python3 - "$WORK/transcript.srt" "$NARRATION" "$WORK/captions.ass" "$ACC_ASS" "$NARR_DUR" "$TRANSCRIBE_OK" "$BRAND" "$CAPTION_FONT" "$CAP_STYLE" "$FONT_SIZE_MULT" "$TEXT_POS" <<'PYEOF'
import sys, re
srt_path, narr_text, out, acc, narr_dur, ok, brand, font, cap_style, font_mult, text_pos = sys.argv[1:12]
narr_dur = float(narr_dur); ok = (ok == "1")
try: font_mult = float(font_mult)
except: font_mult = 1.0
# Map position to ASS Alignment numpad + MarginV
POS_MAP = {"bottom-center": (2, 110), "lower-third": (2, 220), "top-center": (8, 90), "center": (5, 0)}
align, margin_v = POS_MAP.get(text_pos, (2, 110))
RLE = "\u202B"; PDF = "\u202C"
def bidi(s): return RLE + s.strip() + PDF
def srt_ts_to_sec(ts):
  h,m,rest = ts.split(":"); s,ms = rest.split(",")
  return int(h)*3600 + int(m)*60 + int(s) + int(ms)/1000
def t(sec):
  h=int(sec//3600); m=int((sec%3600)//60); s=sec%60
  return f"{h:d}:{m:02d}:{s:05.2f}"
lines = []
if ok:
  try:
    raw = open(srt_path, encoding="utf-8").read()
    pattern = re.compile(r'(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})\s*\n([\s\S]*?)(?=\n\s*\n|\n*$)', re.MULTILINE)
    for m in pattern.finditer(raw):
      start = srt_ts_to_sec(m.group(2)); end = srt_ts_to_sec(m.group(3))
      txt = " ".join(m.group(4).split())
      if txt and end > start: lines.append((start, end, txt))
  except Exception as e:
    print(f"SRT parse error: {e}", file=sys.stderr)
if not lines:
  chunks = [s.strip() for s in re.split(r'[.!?]\s+', narr_text) if s.strip()]
  if not chunks: chunks = [narr_text]
  per = narr_dur / len(chunks); cur = 0.0
  for c in chunks:
    lines.append((cur, cur+per-0.05, c)); cur += per
# Caption style presets (cherry-picked from Kevin69007/projet-montage-video-client/pipeline/styles.json, RTL-adapted for Hebrew)
# Style fields: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut,
#               ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
def fs(base):
  # apply font_size_multiplier (clamped 0.7-2.0 for sanity)
  m = max(0.7, min(2.0, font_mult))
  return int(round(base * m))
CAP_STYLES = {
  "bold":    f"Style: Caption,{font},{fs(54)},&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,96,100,-1,0,1,3,3,{align},140,140,{margin_v},1",
  "hormozi": f"Style: Caption,{font},{fs(66)},&H0000D7FF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,98,100,-1,0,1,5,4,{align},120,120,{margin_v},1",
  "minimal": f"Style: Caption,{font},{fs(48)},&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,1,2,{align},180,180,{margin_v},1",
  "neon":    f"Style: Caption,{font},{fs(58)},{acc},&H000000FF,&H00000000,&H80000000,-1,0,0,0,96,100,-1,0,1,2,8,{align},140,140,{margin_v},1",
}
header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 2
ScaledBorderAndShadow: yes
YCbCr Matrix: TV.709

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
{CAP_STYLES.get(cap_style, CAP_STYLES['bold'])}
Style: Brand,{font},30,&H00FFFFFF,&H000000FF,{acc},&H80000000,-1,0,0,0,96,100,2,0,1,2,1,9,48,48,48,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
events = []
for (s,e,txt) in lines:
  if e-s < 0.2: e = s + 0.8
  events.append(f"Dialogue: 0,{t(s)},{t(e)},Caption,,0,0,0,,{{\\fad(150,120)}}{bidi(txt)}")
if brand and brand.strip():
  events.append(f"Dialogue: 0,0:00:00.00,9:00:00.00,Brand,,0,0,0,,{bidi(brand)}")
open(out, "w", encoding="utf-8").write(header + "\n".join(events) + "\n")
PYEOF

  send_progress "🎨 5/8 — מוסיף סטיילינג..."
  echo "[produce/5] burn captions + brand..." >&2
  local VF="vignette=PI/5,noise=alls=4:allf=t+u"
  if [ "$CAPTIONS" = "on" ] && [ -s "$WORK/captions.ass" ]; then
    VF="${VF},ass=${WORK}/captions.ass:fontsdir=${FONTS_DIR}"
  fi
  ffmpeg -y -i "$WORK/body-raw.mp4" -vf "$VF" -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -c:a copy "$WORK/body-styled.mp4" -loglevel error

  send_progress "🎬 6/8 — בונה intro/outro..."
  echo "[produce/6] intro + outro + end-logo..." >&2
  local TITLE; TITLE=$(jq -r '.title // ""' "$PLAN_FILE")
  local SUBTITLE; SUBTITLE=$(jq -r '.subtitle // ""' "$PLAN_FILE")
  local OUTRO; OUTRO=$(jq -r '.outro // ""' "$PLAN_FILE")
  local END_LOGO_PATH; END_LOGO_PATH=$(jq -r '.end_logo // ""' "$PLAN_FILE")

  > "$WORK/final-list.txt"
  local INTRO_DUR=0
  if [ -n "$TITLE" ]; then
    INTRO_DUR=2.5
    render_card "$WORK/intro.mp4" "$INTRO_DUR" "$TITLE" "$SUBTITLE" "intro" "$W" "$H"
    if [ -s "$WORK/intro.mp4" ]; then
      ffmpeg -y -i "$WORK/intro.mp4" -f lavfi -t "$INTRO_DUR" -i anullsrc=r=48000:cl=stereo \
        -vf "scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:black,fps=30,setsar=1" \
        -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest \
        "$WORK/intro-norm.mp4" -loglevel error
      echo "file 'intro-norm.mp4'" >> "$WORK/final-list.txt"
    else
      INTRO_DUR=0
    fi
  fi

  cp "$WORK/body-styled.mp4" "$WORK/body.mp4"
  echo "file 'body.mp4'" >> "$WORK/final-list.txt"

  local OUTRO_DUR=0
  if [ -n "$OUTRO" ]; then
    OUTRO_DUR=2.0
    render_card "$WORK/outro.mp4" "$OUTRO_DUR" "${BRAND:-$TITLE}" "$OUTRO" "outro" "$W" "$H"
    if [ -s "$WORK/outro.mp4" ]; then
      ffmpeg -y -i "$WORK/outro.mp4" -f lavfi -t "$OUTRO_DUR" -i anullsrc=r=48000:cl=stereo \
        -vf "scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:black,fps=30,setsar=1" \
        -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest \
        "$WORK/outro-norm.mp4" -loglevel error
      echo "file 'outro-norm.mp4'" >> "$WORK/final-list.txt"
    else
      OUTRO_DUR=0
    fi
  fi

  if [ -n "$END_LOGO_PATH" ] && [ -f "$END_LOGO_PATH" ]; then
    local END_DUR=2.2
    local FADE_OUT; FADE_OUT=$(awk "BEGIN{printf \"%.2f\", $END_DUR-0.4}")
    ffmpeg -y \
      -f lavfi -t "$END_DUR" -i "color=c=${BG}:s=${W}x${H}:r=30" \
      -loop 1 -t "$END_DUR" -i "$END_LOGO_PATH" \
      -f lavfi -t "$END_DUR" -i "anullsrc=r=48000:cl=stereo" \
      -filter_complex "[1:v]scale=$(awk "BEGIN{printf \"%d\", $W*0.45}"):-1[lg];[0:v][lg]overlay=(W-w)/2:(H-h)/2:eval=init[bg];[bg]fade=t=in:st=0:d=0.4,fade=t=out:st=${FADE_OUT}:d=0.4,setsar=1[v]" \
      -map "[v]" -map 2:a \
      -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 128k -ar 48000 -ac 2 \
      -t "$END_DUR" \
      "$WORK/end-logo.mp4" -loglevel error 2>/dev/null
    [ -s "$WORK/end-logo.mp4" ] && echo "file 'end-logo.mp4'" >> "$WORK/final-list.txt"
  fi

  # Concat video-only (drop all per-clip audio to avoid stream discontinuities — narration+music added clean below)
  ffmpeg -y -f concat -safe 0 -i "$WORK/final-list.txt" -an -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p "$WORK/final-silent.mp4" -loglevel error
  local FINAL_DUR; FINAL_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$WORK/final-silent.mp4")

  send_progress "🎵 7/8 — מערבב אודיו..."
  echo "[produce/7] music + audio mix (source=${MUSIC_SOURCE})..." >&2
  local MUSIC_AVAILABLE=0
  local MUSIC_MOOD; MUSIC_MOOD=$(jq -r '.music_mood' "$PLAN_FILE")
  local MUS_DUR_MS; MUS_DUR_MS=$(awk "BEGIN{printf \"%d\", $FINAL_DUR*1000}")

  _try_musiclib() {
    command -v musiclib >/dev/null 2>&1 || return 1
    musiclib pick --mood="$MUSIC_MOOD" --duration=20-90 --dest="$WORK/music.mp3" >/dev/null 2>&1 && return 0
    return 1
  }
  _try_elevenlabs_music() {
    [ -z "$ELEVENLABS_API_KEY" ] && return 1
    local prompt="$MUSIC_PROMPT"
    if [ -z "$prompt" ]; then
      prompt="instrumental cinematic track, mood: ${MUSIC_MOOD}, ${LOOK} aesthetic, builds tension with arc, fits ${FINAL_DUR}s narrative, no vocals"
    fi
    echo "[produce/7] elevenlabs music prompt: ${prompt}" >&2
    local code; code=$(curl -sS -o "$WORK/music.mp3" -w "%{http_code}" -X POST "https://api.elevenlabs.io/v1/music" \
      -H "xi-api-key: ${ELEVENLABS_API_KEY}" -H "Content-Type: application/json" \
      -d "$(jq -n --arg p "$prompt" --argjson d "$MUS_DUR_MS" '{prompt:$p, duration_ms:$d, instrumental:true, output_format:"mp3_44100_128"}')")
    if [ "$code" = "200" ] && [ -s "$WORK/music.mp3" ]; then return 0; fi
    rm -f "$WORK/music.mp3"
    echo "[produce/7] elevenlabs music failed (http $code)" >&2
    return 1
  }

  case "$MUSIC_SOURCE" in
    musiclib)
      if _try_musiclib; then MUSIC_AVAILABLE=1
      else echo "[produce/7] WARN: --music-source musiclib requested but failed (CLI missing or pick failed) — continuing without music" >&2
      fi
      ;;
    elevenlabs)
      if _try_elevenlabs_music; then MUSIC_AVAILABLE=1
      else echo "[produce/7] WARN: --music-source elevenlabs requested but failed (API key missing or call failed) — continuing without music" >&2
      fi
      ;;
    auto|*)
      if _try_musiclib; then
        MUSIC_AVAILABLE=1
      elif _try_elevenlabs_music; then
        MUSIC_AVAILABLE=1
      fi
      ;;
  esac
  unset -f _try_musiclib _try_elevenlabs_music
  [ "$MUSIC_AVAILABLE" = "1" ] && echo "[produce/7] music ready: $(du -h "$WORK/music.mp3" | cut -f1)" >&2 || echo "[produce/7] no music — narration only" >&2
  local NARR_DELAY_MS; NARR_DELAY_MS=$(awk "BEGIN{printf \"%d\", ($INTRO_DUR+0.4)*1000}")

  # v1.6: audio_mix enrichment — narration_volume + music_volume (defaults preserve prior behavior)
  local NARR_VOL; NARR_VOL=$(jq -r '.audio_mix.narration_volume // 1.25' "$PLAN_FILE")
  local MUSIC_VOL; MUSIC_VOL=$(jq -r '.audio_mix.music_volume // 0.18' "$PLAN_FILE")

  # Build silent base track for full duration (so amix has a stable spine to align to)
  ffmpeg -y -f lavfi -t "$FINAL_DUR" -i "anullsrc=r=48000:cl=stereo" -c:a aac -b:a 96k "$WORK/silent-base.aac" -loglevel error
  if [ "$MUSIC_AVAILABLE" = "1" ]; then
    local FILTER="[0:a]anull[base];
[1:a]adelay=${NARR_DELAY_MS}|${NARR_DELAY_MS},apad,atrim=0:${FINAL_DUR},volume=${NARR_VOL},asplit=2[narrMix][narrSC];
[2:a]volume=${MUSIC_VOL},atrim=0:${FINAL_DUR}[mus];
[mus][narrSC]sidechaincompress=threshold=0.04:ratio=10:attack=5:release=250[musducked];
[base][narrMix][musducked]amix=inputs=3:duration=first:normalize=0,alimiter=limit=0.97[aout]"
    ffmpeg -y -i "$WORK/silent-base.aac" -i "$WORK/narration.mp3" -stream_loop -1 -i "$WORK/music.mp3" -i "$WORK/final-silent.mp4" \
      -filter_complex "$FILTER" -map 3:v -map "[aout]" \
      -vf "fps=30,format=yuv420p,scale=${W}:${H}:flags=lanczos" -c:v libx264 -preset medium -crf 22 -profile:v baseline -level 3.1 \
      -x264-params keyint=60:min-keyint=60:scenecut=0:bframes=0 -vsync cfr -r 30 -pix_fmt yuv420p \
      -c:a aac -b:a 128k -ar 44100 -ac 2 -movflags +faststart -fflags +genpts -t "$FINAL_DUR" \
      "/tmp/ai-video-result-${PLAN_ID}.mp4" -loglevel error
  else
    local FILTER="[0:a]anull[base];
[1:a]adelay=${NARR_DELAY_MS}|${NARR_DELAY_MS},apad,atrim=0:${FINAL_DUR},volume=${NARR_VOL}[narr];
[base][narr]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.97[aout]"
    ffmpeg -y -i "$WORK/silent-base.aac" -i "$WORK/narration.mp3" -i "$WORK/final-silent.mp4" \
      -filter_complex "$FILTER" -map 2:v -map "[aout]" \
      -vf "fps=30,format=yuv420p,scale=${W}:${H}:flags=lanczos" -c:v libx264 -preset medium -crf 22 -profile:v baseline -level 3.1 \
      -x264-params keyint=60:min-keyint=60:scenecut=0:bframes=0 -vsync cfr -r 30 -pix_fmt yuv420p \
      -c:a aac -b:a 128k -ar 44100 -ac 2 -movflags +faststart -fflags +genpts -t "$FINAL_DUR" \
      "/tmp/ai-video-result-${PLAN_ID}.mp4" -loglevel error
  fi

  send_progress "✅ 8/8 — סיים. שולח..."

  jq --arg pid "$PLAN_ID" '.status = "produced" | .produced_at = (now | todate)' "$PLAN_FILE" > "$PLAN_FILE.tmp" && mv "$PLAN_FILE.tmp" "$PLAN_FILE"

  # ───────── v1.6: Gemini Video critique (Phase 1: report-only) ─────────
  local FINAL_MP4="/tmp/ai-video-result-${PLAN_ID}.mp4"
  if [ "$CRITIQUE" = "on" ]; then
    send_progress "🎬 ביקורת Gemini..."
    echo "[produce/critique] running Gemini Video critique on ${FINAL_MP4}..." >&2
    local CRITIQUE_OUT="/tmp/ai-video-critique-${PLAN_ID}.json"
    local CRITIQUE_HELPER="/home/node/.openclaw/workspace/scripts/gemini-critique.cjs"
    if [ -f "$CRITIQUE_HELPER" ]; then
      local BRIEF_TEXT; BRIEF_TEXT=$(jq -r '.title + ". " + .narration' "$PLAN_FILE")
      if NODE_PATH=/app/node_modules node "$CRITIQUE_HELPER" "$FINAL_MP4" "$BRIEF_TEXT" "$CRITIQUE_OUT" "$PLAN_FILE" 2>&1 | tail -20 >&2; then
        echo "[produce/critique] saved to $CRITIQUE_OUT" >&2
        local SCORE; SCORE=$(jq -r '.overall_score // "n/a"' "$CRITIQUE_OUT" 2>/dev/null)
        local READY; READY=$(jq -r '.ready_to_ship // false' "$CRITIQUE_OUT" 2>/dev/null)
        local P0; P0=$(jq '[.issues[] | select(.severity=="P0")] | length' "$CRITIQUE_OUT" 2>/dev/null)
        local P1; P1=$(jq '[.issues[] | select(.severity=="P1")] | length' "$CRITIQUE_OUT" 2>/dev/null)
        send_progress "🎬 ציון: ${SCORE}/10 — P0:${P0} P1:${P1} — ship:${READY}"
        echo "[produce/critique] score=${SCORE} ready=${READY} P0=${P0} P1=${P1}" >&2
      else
        echo "[produce/critique] failed — continuing without critique" >&2
      fi
    else
      echo "[produce/critique] helper not found at $CRITIQUE_HELPER — skipping" >&2
    fi
  fi

  echo "$FINAL_MP4"
}

# ───────── Helper: render a motion-graphic via HyperFrames + chromakey ─────────
# Each MG type emits an mp4 overlay with magenta (#FF00FF) background, chromakey-stripped at composite.
render_mg_overlay() {
  local TYPE="$1" DATA="$2" OUT="$3" CW="$4" CH="$5" DUR="$6" ACC_HEX="$7" BG_HEX="$8"
  local DIR; DIR=$(mktemp -d)
  # Optional MG font overrides (point env vars at OTF files on disk).
  # If unset, HyperFrames falls back to browser default fonts (Hebrew may render with whatever the
  # host has installed). For Hebrew quality, set these to a font with Hebrew glyphs.
  [ -n "$FONT_HEAVY" ] && [ -f "$FONT_HEAVY" ] && cp "$FONT_HEAVY" "$DIR/heavy.otf" 2>/dev/null || true
  [ -n "$FONT_BOLD"  ] && [ -f "$FONT_BOLD"  ] && cp "$FONT_BOLD"  "$DIR/bold.otf"  2>/dev/null || true
  [ -n "$FONT_LIGHT" ] && [ -f "$FONT_LIGHT" ] && cp "$FONT_LIGHT" "$DIR/light.otf" 2>/dev/null || true
  [ -n "$FONT_SERIF" ] && [ -f "$FONT_SERIF" ] && cp "$FONT_SERIF" "$DIR/serif.otf" 2>/dev/null || true
  case "$TYPE" in
    hero_stat)    generate_hero_stat_html "$DATA" "$CW" "$CH" "$DUR" "$ACC_HEX" "$BG_HEX" > "$DIR/index.html" ;;
    metric_bar)   generate_metric_bar_html "$DATA" "$CW" "$CH" "$DUR" "$ACC_HEX" "$BG_HEX" > "$DIR/index.html" ;;
    bottom_panel) generate_bottom_panel_html "$DATA" "$CW" "$CH" "$DUR" "$ACC_HEX" "$BG_HEX" > "$DIR/index.html" ;;
    mockup_ui)    generate_mockup_ui_html "$DATA" "$CW" "$CH" "$DUR" "$ACC_HEX" "$BG_HEX" > "$DIR/index.html" ;;
    brand_card)   generate_brand_card_html "$DATA" "$CW" "$CH" "$DUR" "$ACC_HEX" "$BG_HEX" > "$DIR/index.html" ;;
    *) rm -rf "$DIR"; return 1 ;;
  esac
  # Render to MOV with TRUE alpha (HF supports transparency in MOV/WebM only).
  # Output extension forced to .mov for proper alpha channel.
  local MOV_OUT="${OUT%.mp4}.mov"
  (cd "$DIR" && hyperframes lint >/dev/null 2>&1 && hyperframes render --workers 2 --format mov --output "$MOV_OUT" >/dev/null 2>&1) || { rm -rf "$DIR"; return 1; }
  if [ -s "$MOV_OUT" ]; then
    mv "$MOV_OUT" "$OUT"
  fi
  rm -rf "$DIR"
  [ -s "$OUT" ]
}

# ─── HTML generators (all use chromakey background #FF00FF) ───
generate_hero_stat_html() {
  local DATA="$1" CW="$2" CH="$3" DUR="$4" ACC="$5" BG="$6"
  local VAL; VAL=$(echo "$DATA" | jq -r '.value // ""')
  local LABEL; LABEL=$(echo "$DATA" | jq -r '.label // ""')
  cat <<HTML
<!doctype html><html lang="he" dir="rtl"><head><meta charset="UTF-8"/>
<meta name="viewport" content="width=${CW}, height=${CH}"/>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>
@font-face{font-family:'Heavy';src:url('./heavy.otf') format('opentype');font-weight:900}
@font-face{font-family:'Light';src:url('./light.otf') format('opentype');font-weight:300}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:${CW}px;height:${CH}px;overflow:hidden;background:transparent;font-family:'Heavy',sans-serif}
.w{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center}
.num{font-family:'Heavy',sans-serif;font-weight:900;font-size:380px;line-height:1;letter-spacing:-12px;color:${ACC};text-shadow:0 0 24px rgba(0,0,0,0.6),0 6px 20px rgba(0,0,0,0.5);-webkit-text-stroke:2px rgba(0,0,0,0.45)}
.lbl{margin-top:30px;font-family:'Light',sans-serif;font-size:64px;font-weight:300;color:#fff;letter-spacing:1px;text-shadow:0 0 16px rgba(0,0,0,0.85),0 3px 10px rgba(0,0,0,0.7);-webkit-text-stroke:1px rgba(0,0,0,0.35)}
</style></head><body>
<div id="root" data-composition-id="main" data-start="0" data-duration="${DUR}" data-width="${CW}" data-height="${CH}">
  <div class="w clip" data-start="0" data-duration="${DUR}" data-track-index="0">
    <div id="num" class="num">${VAL}</div>
    <div id="lbl" class="lbl">${LABEL}</div>
  </div>
</div>
<script>
window.__timelines={};
const tl=gsap.timeline({paused:true});
tl.from("#num",{scale:0.4,opacity:0,duration:0.7,ease:"back.out(2)"},0.05)
  .from("#lbl",{y:30,opacity:0,duration:0.5,ease:"power3.out"},0.45)
  .to(["#num","#lbl"],{opacity:0,duration:0.3,ease:"power2.in"},${DUR}-0.3);
window.__timelines["main"]=tl;
</script></body></html>
HTML
}

generate_metric_bar_html() {
  local DATA="$1" CW="$2" CH="$3" DUR="$4" ACC="$5" BG="$6"
  local VAL; VAL=$(echo "$DATA" | jq -r '.value // ""')
  local LABEL; LABEL=$(echo "$DATA" | jq -r '.label // ""')
  local PREFIX; PREFIX=$(echo "$DATA" | jq -r '.prefix // ""')
  local SUFFIX; SUFFIX=$(echo "$DATA" | jq -r '.suffix // ""')
  cat <<HTML
<!doctype html><html lang="he" dir="rtl"><head><meta charset="UTF-8"/>
<meta name="viewport" content="width=${CW}, height=${CH}"/>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>
@font-face{font-family:'Heavy';src:url('./heavy.otf') format('opentype');font-weight:900}
@font-face{font-family:'Light';src:url('./light.otf') format('opentype');font-weight:300}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:${CW}px;height:${CH}px;overflow:hidden;background:transparent;font-family:'Heavy',sans-serif}
.box{position:absolute;left:50%;top:38%;transform:translate(-50%,-50%);text-align:center;padding:50px 70px;border-radius:24px;background:${BG}f0;border:2px solid ${ACC}66;box-shadow:0 30px 80px rgba(0,0,0,0.6)}
.kicker{font-family:'Light',sans-serif;font-weight:300;font-size:32px;color:${ACC};letter-spacing:3px;text-transform:uppercase;margin-bottom:8px}
.row{display:flex;align-items:baseline;justify-content:center;gap:8px}
.pre{font-family:'Light',sans-serif;font-size:60px;color:${ACC}}
.num{font-family:'Heavy',sans-serif;font-size:240px;line-height:1;letter-spacing:-8px;color:#fff;text-shadow:0 6px 20px rgba(0,0,0,0.5)}
.suf{font-family:'Light',sans-serif;font-size:60px;color:${ACC}}
.lbl{margin-top:20px;font-family:'Light',sans-serif;font-size:42px;color:#fff;letter-spacing:1px}
.bars{margin-top:32px;display:flex;align-items:flex-end;justify-content:center;gap:10px;height:90px}
.bar{width:36px;background:${ACC};border-radius:6px;transform-origin:bottom}
</style></head><body>
<div id="root" data-composition-id="main" data-start="0" data-duration="${DUR}" data-width="${CW}" data-height="${CH}">
  <div class="box clip" data-start="0" data-duration="${DUR}" data-track-index="0">
    <div class="kicker">התוצאה</div>
    <div class="row">
      $([ -n "$PREFIX" ] && echo "<span class=\"pre\">${PREFIX}</span>")
      <span id="num" class="num">${VAL}</span>
      $([ -n "$SUFFIX" ] && echo "<span class=\"suf\">${SUFFIX}</span>")
    </div>
    <div class="lbl">${LABEL}</div>
    <div class="bars">
      <div class="bar" style="height:30%"></div>
      <div class="bar" style="height:50%"></div>
      <div class="bar" style="height:65%"></div>
      <div class="bar" style="height:80%"></div>
      <div class="bar" style="height:95%"></div>
      <div class="bar" style="height:60%"></div>
    </div>
  </div>
</div>
<script>
window.__timelines={};
const tl=gsap.timeline({paused:true});
tl.from(".box",{scale:0.8,opacity:0,duration:0.55,ease:"back.out(1.6)"},0.05)
  .from("#num",{textContent:0,duration:0.9,ease:"power2.out",snap:{textContent:1}},0.2)
  .from(".bar",{scaleY:0,duration:0.6,stagger:0.06,ease:"back.out(1.8)"},0.4)
  .to(".box",{opacity:0,duration:0.3,ease:"power2.in"},${DUR}-0.3);
window.__timelines["main"]=tl;
</script></body></html>
HTML
}

generate_bottom_panel_html() {
  local DATA="$1" CW="$2" CH="$3" DUR="$4" ACC="$5" BG="$6"
  local M1L; M1L=$(echo "$DATA" | jq -r '.metrics[0].label // ""')
  local M1V; M1V=$(echo "$DATA" | jq -r '.metrics[0].value // ""')
  local M2L; M2L=$(echo "$DATA" | jq -r '.metrics[1].label // ""')
  local M2V; M2V=$(echo "$DATA" | jq -r '.metrics[1].value // ""')
  local M3L; M3L=$(echo "$DATA" | jq -r '.metrics[2].label // ""')
  local M3V; M3V=$(echo "$DATA" | jq -r '.metrics[2].value // ""')
  cat <<HTML
<!doctype html><html lang="he" dir="rtl"><head><meta charset="UTF-8"/>
<meta name="viewport" content="width=${CW}, height=${CH}"/>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>
@font-face{font-family:'Heavy';src:url('./heavy.otf') format('opentype');font-weight:900}
@font-face{font-family:'Light';src:url('./light.otf') format('opentype');font-weight:300}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:${CW}px;height:${CH}px;overflow:hidden;background:transparent;font-family:'Heavy',sans-serif}
.panel{position:absolute;bottom:60px;left:60px;right:60px;height:180px;background:${BG}f0;border-radius:18px;border:1px solid ${ACC}33;backdrop-filter:blur(20px);display:flex;align-items:center;justify-content:space-around;box-shadow:0 20px 60px rgba(0,0,0,0.5)}
.metric{text-align:center;flex:1;display:flex;flex-direction:column;gap:6px}
.metric .l{font-family:'Light',sans-serif;font-size:24px;color:#aab2c0;letter-spacing:3px;text-transform:uppercase;font-weight:300}
.metric .v{font-family:'Heavy',sans-serif;font-size:88px;color:${ACC};line-height:1;letter-spacing:-3px}
.sep{width:1px;height:100px;background:${ACC}33}
</style></head><body>
<div id="root" data-composition-id="main" data-start="0" data-duration="${DUR}" data-width="${CW}" data-height="${CH}">
  <div class="panel clip" data-start="0" data-duration="${DUR}" data-track-index="0">
    <div class="metric m1"><div class="l">${M1L}</div><div class="v">${M1V}</div></div>
    $([ -n "$M2V" ] && echo "<div class=\"sep\"></div><div class=\"metric m2\"><div class=\"l\">${M2L}</div><div class=\"v\">${M2V}</div></div>")
    $([ -n "$M3V" ] && echo "<div class=\"sep\"></div><div class=\"metric m3\"><div class=\"l\">${M3L}</div><div class=\"v\">${M3V}</div></div>")
  </div>
</div>
<script>
window.__timelines={};
const tl=gsap.timeline({paused:true});
tl.from(".panel",{y:200,opacity:0,duration:0.6,ease:"power3.out"},0)
  .from(".m1 .v",{scale:0.5,opacity:0,duration:0.5,ease:"back.out(1.8)"},0.4)
  .from(".m2 .v",{scale:0.5,opacity:0,duration:0.5,ease:"back.out(1.8)"},0.55)
  .from(".m3 .v",{scale:0.5,opacity:0,duration:0.5,ease:"back.out(1.8)"},0.7)
  .to(".panel",{y:200,opacity:0,duration:0.4,ease:"power2.in"},${DUR}-0.4);
window.__timelines["main"]=tl;
</script></body></html>
HTML
}

generate_mockup_ui_html() {
  local DATA="$1" CW="$2" CH="$3" DUR="$4" ACC="$5" BG="$6"
  local TITLE; TITLE=$(echo "$DATA" | jq -r '.title // ""')
  local L1; L1=$(echo "$DATA" | jq -r '.lines[0] // ""')
  local L2; L2=$(echo "$DATA" | jq -r '.lines[1] // ""')
  local L3; L3=$(echo "$DATA" | jq -r '.lines[2] // ""')
  cat <<HTML
<!doctype html><html lang="he" dir="rtl"><head><meta charset="UTF-8"/>
<meta name="viewport" content="width=${CW}, height=${CH}"/>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>
@font-face{font-family:'Heavy';src:url('./heavy.otf') format('opentype');font-weight:900}
@font-face{font-family:'Bold';src:url('./bold.otf') format('opentype');font-weight:700}
@font-face{font-family:'Light';src:url('./light.otf') format('opentype');font-weight:300}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:${CW}px;height:${CH}px;overflow:hidden;background:#FF00FF;font-family:'Bold',sans-serif}
.card{position:absolute;top:80px;left:80px;width:880px;background:${BG}f5;border-radius:20px;border:1px solid ${ACC}33;backdrop-filter:blur(20px);padding:36px 44px;box-shadow:0 30px 80px rgba(0,0,0,0.55)}
.head{display:flex;align-items:center;gap:12px;margin-bottom:24px}
.dot{width:14px;height:14px;border-radius:50%;background:${ACC};box-shadow:0 0 12px ${ACC}}
.h{font-family:'Bold',sans-serif;font-size:28px;color:${ACC};letter-spacing:3px;text-transform:uppercase}
.title{font-family:'Heavy',sans-serif;font-size:48px;color:#fff;margin-bottom:18px}
.line{display:flex;gap:14px;align-items:flex-start;margin-bottom:14px;font-family:'Light',sans-serif;font-size:34px;color:#fff;line-height:1.3}
.line .t{font-family:'Bold',sans-serif;color:${ACC};font-size:30px;min-width:70px}
</style></head><body>
<div id="root" data-composition-id="main" data-start="0" data-duration="${DUR}" data-width="${CW}" data-height="${CH}">
  <div class="card clip" data-start="0" data-duration="${DUR}" data-track-index="0">
    <div class="head"><span class="dot"></span><span class="h">${TITLE}</span></div>
    <div class="title">תצוגה חיה</div>
    $([ -n "$L1" ] && echo "<div class=\"line l1\"><span class=\"t\">›</span><span>${L1}</span></div>")
    $([ -n "$L2" ] && echo "<div class=\"line l2\"><span class=\"t\">›</span><span>${L2}</span></div>")
    $([ -n "$L3" ] && echo "<div class=\"line l3\"><span class=\"t\">›</span><span>${L3}</span></div>")
  </div>
</div>
<script>
window.__timelines={};
const tl=gsap.timeline({paused:true});
tl.from(".card",{x:-200,opacity:0,duration:0.5,ease:"power3.out"},0)
  .from(".l1",{x:30,opacity:0,duration:0.4,ease:"power3.out"},0.4)
  .from(".l2",{x:30,opacity:0,duration:0.4,ease:"power3.out"},0.6)
  .from(".l3",{x:30,opacity:0,duration:0.4,ease:"power3.out"},0.8)
  .to(".card",{x:-200,opacity:0,duration:0.4,ease:"power2.in"},${DUR}-0.4);
window.__timelines["main"]=tl;
</script></body></html>
HTML
}

generate_brand_card_html() {
  local DATA="$1" CW="$2" CH="$3" DUR="$4" ACC="$5" BG="$6"
  local NAME; NAME=$(echo "$DATA" | jq -r '.name // ""')
  local TAGLINE; TAGLINE=$(echo "$DATA" | jq -r '.tagline // ""')
  cat <<HTML
<!doctype html><html lang="he" dir="rtl"><head><meta charset="UTF-8"/>
<meta name="viewport" content="width=${CW}, height=${CH}"/>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>
@font-face{font-family:'Heavy';src:url('./heavy.otf') format('opentype');font-weight:900}
@font-face{font-family:'Light';src:url('./light.otf') format('opentype');font-weight:300}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:${CW}px;height:${CH}px;overflow:hidden;background:transparent;font-family:'Heavy',sans-serif}
.w{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:28px}
.box{padding:30px 80px;border:3px solid ${ACC};border-radius:14px;background:rgba(0,0,0,0.45);backdrop-filter:blur(6px)}
.name{font-family:'Heavy',sans-serif;font-size:200px;line-height:1;letter-spacing:-6px;color:#fff;text-shadow:0 4px 20px rgba(0,0,0,0.55)}
.tagline{font-family:'Light',sans-serif;font-size:46px;color:${ACC};letter-spacing:1px;text-align:center;text-shadow:0 0 18px rgba(0,0,0,0.85),0 3px 10px rgba(0,0,0,0.7)}
</style></head><body>
<div id="root" data-composition-id="main" data-start="0" data-duration="${DUR}" data-width="${CW}" data-height="${CH}">
  <div class="w clip" data-start="0" data-duration="${DUR}" data-track-index="0">
    <div class="box"><div class="name">${NAME}</div></div>
    $([ -n "$TAGLINE" ] && echo "<div class=\"tagline\">${TAGLINE}</div>")
  </div>
</div>
<script>
window.__timelines={};
const tl=gsap.timeline({paused:true});
tl.from(".box",{scale:0.85,opacity:0,duration:0.55,ease:"back.out(1.5)"},0)
  .from(".tagline",{y:20,opacity:0,duration:0.45,ease:"power3.out"},0.4)
  .to([".box",".tagline"],{opacity:0,duration:0.35,ease:"power2.in"},${DUR}-0.35);
window.__timelines["main"]=tl;
</script></body></html>
HTML
}

# ───────── Smart placement via Gemini Vision ─────────
# Args: PLAN_FILE SCENE_I ASSET_PATH MGS_JSON CW CH
# Updates the in-place positions in MGS_JSON to avoid the subject
smart_place_mgs() {
  local PLAN_FILE="$1" SCENE_I="$2" ASSET_PATH="$3" MGS_JSON_VAR="$4" CW="$5" CH="$6"
  local MGS="${!MGS_JSON_VAR}"
  local TMP; TMP=$(mktemp -d)
  # Extract a representative frame
  local FRAME="$TMP/frame.jpg"
  ffmpeg -y -ss 0.5 -i "$ASSET_PATH" -frames:v 1 -q:v 3 -vf "scale=640:-1" "$FRAME" -loglevel error 2>/dev/null || cp "$ASSET_PATH" "$FRAME"
  [ ! -s "$FRAME" ] && { rm -rf "$TMP"; return 0; }
  local B64; B64=$(base64 -w0 "$FRAME")
  python3 - "$MGS" "$B64" "$CW" "$CH" "$TMP/body.json" <<'PYEOF'
import json, sys
mgs, b64, cw, ch, out = sys.argv[1:6]
mgs_list = json.loads(mgs)
prompt = f"""You are a video editor. The video frame is {cw}x{ch}. Given motion graphic overlays planned for this frame, decide WHERE each should appear so it does NOT collide with the main subject.

Overlays:
{json.dumps(mgs_list, ensure_ascii=False)}

For each overlay return:
- "i": same as input
- "position": one of "center", "top-left", "top-right", "bottom-left", "bottom-right", "left-third", "right-third", "top-third", "bottom-third"
- "scale": 0.7..1.2 (smaller if subject is busy near where overlay would go)
- "dim_bg": true if the overlay should darken the underlying scene (use for "hero_stat" + "brand_card"; false for "metric_bar" + "bottom_panel" + "mockup_ui" usually)

Respond with ONLY a JSON object: {{"placements": [{{i, position, scale, dim_bg}}]}}"""
body = {
  "contents":[{"parts":[
    {"inlineData":{"mimeType":"image/jpeg","data":b64}},
    {"text":prompt}
  ]}],
  "generationConfig":{"response_mime_type":"application/json","temperature":0.2}
}
json.dump(body, open(out,"w",encoding="utf-8"), ensure_ascii=False)
PYEOF
  local RESP; RESP=$(curl -sS -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_API_KEY}" -H "Content-Type: application/json" --data-binary "@$TMP/body.json")
  local PLACEMENTS; PLACEMENTS=$(echo "$RESP" | jq -r '.candidates[0].content.parts[0].text // empty' | jq -c '.placements // []' 2>/dev/null)
  rm -rf "$TMP"
  if [ -n "$PLACEMENTS" ] && [ "$PLACEMENTS" != "null" ] && [ "$PLACEMENTS" != "[]" ]; then
    # Merge placements into MGS by index
    local NEW; NEW=$(echo "$MGS" | jq --argjson p "$PLACEMENTS" 'map(. as $mg | ($p[] | select(.i == $mg.i)) as $pl | $mg + ($pl // {}))')
    eval "$MGS_JSON_VAR='$NEW'"
  fi
}

# Position resolver: returns "X:Y" coords for the overlay at a given quadrant for canvas CWxCH and overlay W×H
resolve_position() {
  local POS="$1" CW="$2" CH="$3" OW="$4" OH="$5"
  local X Y
  case "$POS" in
    center)        X="(W-w)/2"; Y="(H-h)/2" ;;
    top-left)      X="60"; Y="60" ;;
    top-right)     X="W-w-60"; Y="60" ;;
    bottom-left)   X="60"; Y="H-h-60" ;;
    bottom-right)  X="W-w-60"; Y="H-h-60" ;;
    top-third)     X="(W-w)/2"; Y="60" ;;
    bottom-third)  X="(W-w)/2"; Y="H-h-60" ;;
    left-third)    X="60"; Y="(H-h)/2" ;;
    right-third)   X="W-w-60"; Y="(H-h)/2" ;;
    *)             X="(W-w)/2"; Y="(H-h)/2" ;;
  esac
  echo "${X}:${Y}"
}

# ───────── Helper: apply motion graphics to a clip (HF chromakey + smart placement) ─────────
# Reads .motion_graphics from plan for given scene, renders each via HF chromakey overlay,
# uses Gemini Vision smart placement, then composites with ffmpeg overlay+colorkey.
apply_motion_graphics() {
  local PLAN_FILE="$1" SCENE_I="$2" CLIP_IN="$3" CLIP_OUT="$4" CW="${5:-1920}" CH="${6:-1080}"
  # Add an "i" index to each MG for placement merging
  local MGS; MGS=$(jq -c --arg n "$SCENE_I" '[.motion_graphics[]? | select(.scene == ($n|tonumber))] | to_entries | map(.value + {i: .key})' "$PLAN_FILE")
  local COUNT; COUNT=$(echo "$MGS" | jq 'length')
  if [ "$COUNT" -lt 1 ]; then
    cp "$CLIP_IN" "$CLIP_OUT"
    return 0
  fi

  # Smart placement via Gemini Vision (one call for all MGs in this scene)
  smart_place_mgs "$PLAN_FILE" "$SCENE_I" "$CLIP_IN" MGS "$CW" "$CH" || true

  # Render each MG; for HF-chromakey types, generate overlay mp4 + composite. For drawtext types, fall back to old path.
  local CUR="$CLIP_IN"
  local STAGE_DIR; STAGE_DIR=$(mktemp -d)
  local CHROMA_TYPES="hero_stat metric_bar bottom_panel mockup_ui brand_card"
  for j in $(seq 0 $((COUNT-1))); do
    local MG; MG=$(echo "$MGS" | jq ".[$j]")
    local TYPE; TYPE=$(echo "$MG" | jq -r '.type')
    local IN_AT; IN_AT=$(echo "$MG" | jq -r '.in_at // 0.5')
    local DUR;   DUR=$(echo "$MG" | jq -r '.duration // 3.0')
    local OUT_AT; OUT_AT=$(awk "BEGIN{printf \"%.2f\", $IN_AT + $DUR}")
    local POS; POS=$(echo "$MG" | jq -r '.position // "center"')
    local SCALE; SCALE=$(echo "$MG" | jq -r '.scale // 1.0')

    if [[ " $CHROMA_TYPES " == *" $TYPE "* ]]; then
      # HF chromakey path
      local OVERLAY="$STAGE_DIR/mg_${j}.mp4"
      render_mg_overlay "$TYPE" "$MG" "$OVERLAY" "$CW" "$CH" "$DUR" "$ACC" "$BG" || { echo "  MG $j ($TYPE) render failed, skipping" >&2; continue; }
      [ ! -s "$OVERLAY" ] && { echo "  MG $j ($TYPE) overlay empty, skipping" >&2; continue; }
      # Composite via ffmpeg overlay with chromakey
      # For full-screen types (hero_stat, brand_card) the overlay already covers full canvas — center it
      local POS_X="(W-w)/2" POS_Y="(H-h)/2"
      case "$TYPE" in
        bottom_panel) POS_X="0"; POS_Y="0" ;;  # already positioned bottom in HTML
        mockup_ui)
          case "$POS" in
            top-left|left-third)    POS_X="0"; POS_Y="0" ;;
            top-right|right-third)  POS_X="W-w"; POS_Y="0" ;;
            *)                       POS_X="0"; POS_Y="0" ;;
          esac
          ;;
        metric_bar)
          case "$POS" in
            top-left)      POS_X="0"; POS_Y="0" ;;
            top-right)     POS_X="W-w"; POS_Y="0" ;;
            bottom-left)   POS_X="0"; POS_Y="H-h" ;;
            bottom-right)  POS_X="W-w"; POS_Y="H-h" ;;
            top-third)     POS_X="(W-w)/2"; POS_Y="0" ;;
            bottom-third)  POS_X="(W-w)/2"; POS_Y="H-h" ;;
            *)             POS_X="(W-w)/2"; POS_Y="(H-h)/2" ;;
          esac
          ;;
      esac
      local NEXT="$STAGE_DIR/stage_${j}.mp4"
      ffmpeg -y -i "$CUR" -i "$OVERLAY" \
        -filter_complex "[1:v]format=yuva420p,setpts=PTS-STARTPTS+${IN_AT}/TB[ov];[0:v][ov]overlay=${POS_X}:${POS_Y}:enable='between(t,${IN_AT},${OUT_AT})':eof_action=pass[v]" \
        -map "[v]" -map 0:a? -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -c:a copy "$NEXT" -loglevel error 2>"$STAGE_DIR/err_${j}.txt"
      if [ -s "$NEXT" ]; then
        CUR="$NEXT"
      else
        echo "  MG $j composite failed:" >&2; head -5 "$STAGE_DIR/err_${j}.txt" >&2
      fi
      continue
    fi

    # Unknown / legacy type — skip with a warning
    echo "  MG $j: unsupported type '$TYPE' skipped (use hero_stat/metric_bar/bottom_panel/mockup_ui/brand_card)" >&2
  done

  # Finalize: copy CUR (last stage) to CLIP_OUT
  cp "$CUR" "$CLIP_OUT"
  rm -rf "$STAGE_DIR"
}

# ───────── Helper: render a title/intro/outro card via HyperFrames ─────────
render_card() {
  local OUT="$1" DUR="$2" T="$3" S="$4" KIND="$5" CW="$6" CH="$7"
  local DIR; DIR=$(mktemp -d)
  esc(){ printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
  local TE; TE=$(esc "$T"); local SE; SE=$(esc "$S")
  # Title font per look — generic mapping using Google Fonts.
  # Override per-look via $TITLE_FONT_FILE env (must be an OTF/TTF path with Hebrew glyphs for Hebrew content).
  local FONT_FILE FONT_FAMILY FONT_WEIGHT TITLE_LETTER_SP
  case "$LOOK" in
    modern|tech|neon) FONT_FAMILY="Heebo";         FONT_WEIGHT=900; TITLE_LETTER_SP="-3px" ;;
    medical)          FONT_FAMILY="Heebo";         FONT_WEIGHT=600; TITLE_LETTER_SP="-2px" ;;
    minimal)          FONT_FAMILY="Heebo";         FONT_WEIGHT=300; TITLE_LETTER_SP="0px" ;;
    warm|luxury|classic|*) FONT_FAMILY="Heebo";    FONT_WEIGHT=700; TITLE_LETTER_SP="-2px" ;;
    documentary)      FONT_FAMILY="Heebo";         FONT_WEIGHT=700; TITLE_LETTER_SP="-2px" ;;
  esac
  FONT_FILE="${TITLE_FONT_FILE:-}"
  # If user supplied an OTF/TTF file path, embed it for @font-face relative access
  if [ -n "$FONT_FILE" ] && [ -f "$FONT_FILE" ]; then
    cp "$FONT_FILE" "$DIR/title.otf"
  fi
  local TITLE_SIZE=180; local SUB_SIZE=44
  if [ "$KIND" = "outro" ]; then TITLE_SIZE=150; SUB_SIZE=40; fi
  # Title color per look — flat, no glow
  local TITLE_STYLE
  case "$LOOK" in
    minimal|medical) TITLE_STYLE="color:${FG}" ;;
    modern|tech)     TITLE_STYLE="color:${FG}" ;;
    *)               TITLE_STYLE="background:${GRAD};-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent" ;;
  esac
  cat > "$DIR/index.html" <<HTML
<!doctype html><html lang="he" dir="rtl"><head><meta charset="UTF-8"/>
<meta name="viewport" content="width=${CW}, height=${CH}"/>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
<style>
@font-face{font-family:'${FONT_FAMILY}';src:url('./title.otf') format('opentype');font-weight:${FONT_WEIGHT};font-display:block}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:${CW}px;height:${CH}px;overflow:hidden;background:${BG};font-family:'${FONT_FAMILY}',sans-serif;color:${FG}}
.w{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:18px;padding:0 80px}
.title{font-family:'${FONT_FAMILY}',sans-serif;font-weight:${FONT_WEIGHT};font-size:${TITLE_SIZE}px;line-height:0.95;letter-spacing:${TITLE_LETTER_SP};${TITLE_STYLE}}
.sub{margin-top:18px;font-size:${SUB_SIZE}px;font-weight:400;letter-spacing:1px;opacity:0.95;color:${ACC};padding:12px 36px;border-radius:999px;background:${ACC}22;border:1.5px solid ${ACC}}
</style></head><body>
<div id="root" data-composition-id="main" data-start="0" data-duration="${DUR}" data-width="${CW}" data-height="${CH}">
  <div id="w" class="w clip" data-start="0" data-duration="${DUR}" data-track-index="0">
    <div id="t" class="title">${TE}</div>
    $([ -n "$SE" ] && echo "<div id=\"s\" class=\"sub\">${SE}</div>")
  </div>
</div>
<script>
window.__timelines={};
const tl=gsap.timeline({paused:true});
tl.from("#t",{y:60,opacity:0,scale:0.92,duration:0.9,ease:"power4.out"},0.1)
$([ -n "$SE" ] && echo '.from("#s",{scale:0.7,opacity:0,duration:0.7,ease:"back.out(1.8)"},0.6)')
.to("#w",{opacity:0,duration:0.35,ease:"power2.in"},${DUR}-0.35);
window.__timelines["main"]=tl;
</script></body></html>
HTML
  (cd "$DIR" && hyperframes lint >/dev/null 2>&1 && hyperframes render --workers 2 --output "$OUT" >/dev/null 2>&1) || true
  rm -rf "$DIR"
}

# ───────── Helper: generate one scene's asset ─────────
generate_scene_asset() {
  local PLAN_FILE="$1" SCENE_I="$2" ASSETS_DIR="$3"
  local SC; SC=$(jq --arg n "$SCENE_I" '.scenes[] | select(.i == ($n|tonumber))' "$PLAN_FILE")
  local TYPE; TYPE=$(echo "$SC" | jq -r '.type')
  local MODEL; MODEL=$(echo "$SC" | jq -r '.model')
  local DUR;   DUR=$(echo "$SC" | jq -r '.duration_sec')
  local ASPECT; ASPECT=$(echo "$SC" | jq -r '.aspect')
  local PROMPT; PROMPT=$(echo "$SC" | jq -r '.prompt_final')
  local NEG;    NEG=$(echo "$SC" | jq -r '.negative_prompt // ""')
  local OUT="$ASSETS_DIR/scene_${SCENE_I}.${TYPE/video/mp4}"
  [ "$TYPE" = "image" ] && OUT="$ASSETS_DIR/scene_${SCENE_I}.png"

  echo "  [scene $SCENE_I] $MODEL ($TYPE, ${DUR}s)..." >&2

  case "$MODEL" in
    grok-imagine) call_grok_imagine_video "$PROMPT" "$DUR" "$ASPECT" "$OUT" ;;
    nano-banana-2) call_nano_banana "$PROMPT" "$ASPECT" "$OUT" ;;
    imagen-3.0)   call_imagen3 "$PROMPT" "$ASPECT" "$OUT" ;;
    flux-schnell|flux-pro-1.1) call_flux "$MODEL" "$PROMPT" "$ASPECT" "$OUT" ;;
    ltx-2)        call_ltx2 "$PROMPT" "$DUR" "$ASPECT" "$OUT" ;;
    *) echo "ERROR: unknown model $MODEL" >&2; exit 1 ;;
  esac

  if [ ! -s "$OUT" ]; then
    echo "  scene $SCENE_I generation failed" >&2
    jq --arg n "$SCENE_I" '(.scenes[] | select(.i == ($n|tonumber))) |= (.status="failed")' "$PLAN_FILE" > "$PLAN_FILE.tmp" && mv "$PLAN_FILE.tmp" "$PLAN_FILE"
    return 1
  fi
  jq --arg n "$SCENE_I" --arg p "$OUT" '(.scenes[] | select(.i == ($n|tonumber))) |= (.status="done" | .asset_path=$p)' "$PLAN_FILE" > "$PLAN_FILE.tmp" && mv "$PLAN_FILE.tmp" "$PLAN_FILE"
}

# ───────── Generators ─────────

call_grok_imagine_video() {
  local PROMPT="$1" DUR="$2" ASPECT="$3" OUT="$4"
  [ -z "$XAI_API_KEY" ] && { echo "ERROR: XAI_API_KEY not set" >&2; return 1; }
  local DUR_INT; DUR_INT=$(awk "BEGIN{printf \"%d\", $DUR}")
  local TMP; TMP=$(mktemp)
  jq -n --arg p "$PROMPT" --arg a "$ASPECT" --argjson d "$DUR_INT" \
    '{model:"grok-imagine-video", prompt:$p, duration:$d, aspect_ratio:$a, resolution:"720p"}' > "$TMP"
  local SUB; SUB=$(curl -sS -X POST "https://api.x.ai/v1/videos/generations" \
    -H "Authorization: Bearer ${XAI_API_KEY}" -H "Content-Type: application/json" \
    --data-binary "@$TMP")
  local REQ_ID; REQ_ID=$(echo "$SUB" | jq -r '.request_id // empty')
  if [ -z "$REQ_ID" ]; then echo "  Grok submit failed: $SUB" >&2; rm -f "$TMP"; return 1; fi
  rm -f "$TMP"
  local DEADLINE=$(( $(date +%s) + 600 ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sleep 4
    local POLL; POLL=$(curl -sS "https://api.x.ai/v1/videos/${REQ_ID}" -H "Authorization: Bearer ${XAI_API_KEY}")
    local URL; URL=$(echo "$POLL" | jq -r '.video.url // empty')
    if [ -n "$URL" ]; then curl -sSL "$URL" -o "$OUT"; return 0; fi
    local ST; ST=$(echo "$POLL" | jq -r '.status // empty')
    if [ "$ST" = "expired" ] || [ "$ST" = "failed" ]; then echo "  Grok poll failed: $POLL" >&2; return 1; fi
  done
  echo "  Grok timeout" >&2; return 1
}

call_nano_banana() {
  local PROMPT="$1" ASPECT="$2" OUT="$3"
  # Try Gemini 2.5 Flash Image (Nano Banana 2 codename) first
  local TMP; TMP=$(mktemp)
  jq -n --arg p "$PROMPT" '{contents:[{parts:[{text:$p}]}], generationConfig:{responseModalities:["IMAGE"]}}' > "$TMP"
  for MODEL in gemini-2.5-flash-image gemini-2.5-flash-image-preview imagen-3.0-generate-002; do
    local RESP; RESP=$(curl -sS -X POST "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${GEMINI_API_KEY}" \
      -H "Content-Type: application/json" --data-binary "@$TMP")
    local B64; B64=$(echo "$RESP" | jq -r '.candidates[0].content.parts[]? | select(.inlineData) | .inlineData.data' 2>/dev/null | head -n1)
    if [ -n "$B64" ] && [ "$B64" != "null" ]; then
      echo "$B64" | base64 -d > "$OUT"
      [ -s "$OUT" ] && { rm -f "$TMP"; echo "  used $MODEL" >&2; return 0; }
    fi
  done
  rm -f "$TMP"
  # Final fallback: FLUX
  call_flux "flux-schnell" "$PROMPT" "$ASPECT" "$OUT"
}

call_imagen3() {
  call_nano_banana "$@"
}

call_flux() {
  local MODEL="$1" PROMPT="$2" ASPECT="$3" OUT="$4"
  [ -z "$FAL_KEY" ] && { echo "ERROR: FAL_KEY not set" >&2; return 1; }
  local FAL_MODEL="fal-ai/flux/schnell"
  [ "$MODEL" = "flux-pro-1.1" ] && FAL_MODEL="fal-ai/flux-pro/v1.1"
  local W=1024 H=1024
  case "$ASPECT" in
    "16:9") W=1280; H=720 ;;
    "9:16") W=720; H=1280 ;;
    "1:1")  W=1024; H=1024 ;;
  esac
  local TMP; TMP=$(mktemp)
  jq -n --arg p "$PROMPT" --argjson w $W --argjson h $H \
    '{prompt:$p, image_size:{width:$w, height:$h}, num_inference_steps:4}' > "$TMP"
  local SUB; SUB=$(curl -sS -X POST "https://queue.fal.run/${FAL_MODEL}" \
    -H "Authorization: Key ${FAL_KEY}" -H "Content-Type: application/json" \
    --data-binary "@$TMP")
  rm -f "$TMP"
  local STATUS_URL; STATUS_URL=$(echo "$SUB" | jq -r '.status_url // empty')
  local RESP_URL;   RESP_URL=$(echo "$SUB" | jq -r '.response_url // empty')
  if [ -z "$STATUS_URL" ]; then echo "  FLUX submit failed: $SUB" >&2; return 1; fi
  local DEADLINE=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sleep 2
    local POLL; POLL=$(curl -sS "$STATUS_URL" -H "Authorization: Key ${FAL_KEY}")
    local ST; ST=$(echo "$POLL" | jq -r '.status // empty')
    if [ "$ST" = "COMPLETED" ]; then
      local R; R=$(curl -sS "$RESP_URL" -H "Authorization: Key ${FAL_KEY}")
      local URL; URL=$(echo "$R" | jq -r '.images[0].url // empty')
      if [ -n "$URL" ]; then curl -sSL "$URL" -o "$OUT"; return 0; fi
    fi
    [ "$ST" = "FAILED" ] || [ "$ST" = "ERROR" ] && { echo "  FLUX failed: $POLL" >&2; return 1; }
  done
  echo "  FLUX timeout" >&2; return 1
}

call_ltx2() {
  local PROMPT="$1" DUR="$2" ASPECT="$3" OUT="$4"
  [ -z "$FAL_KEY" ] && { echo "ERROR: FAL_KEY not set" >&2; return 1; }
  local W=768 H=432
  case "$ASPECT" in
    "9:16") W=432; H=768 ;;
    "1:1")  W=512; H=512 ;;
  esac
  local FRAMES; FRAMES=$(awk "BEGIN{printf \"%d\", $DUR*24}")
  local TMP; TMP=$(mktemp)
  jq -n --arg p "$PROMPT" --argjson w $W --argjson h $H --argjson f $FRAMES \
    '{prompt:$p, num_frames:$f, width:$w, height:$h}' > "$TMP"
  local SUB; SUB=$(curl -sS -X POST "https://queue.fal.run/fal-ai/ltx-2/text-to-video" \
    -H "Authorization: Key ${FAL_KEY}" -H "Content-Type: application/json" \
    --data-binary "@$TMP")
  rm -f "$TMP"
  local STATUS_URL; STATUS_URL=$(echo "$SUB" | jq -r '.status_url // empty')
  local RESP_URL;   RESP_URL=$(echo "$SUB" | jq -r '.response_url // empty')
  if [ -z "$STATUS_URL" ]; then echo "  LTX submit failed: $SUB" >&2; return 1; fi
  local DEADLINE=$(( $(date +%s) + 360 ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sleep 4
    local POLL; POLL=$(curl -sS "$STATUS_URL" -H "Authorization: Key ${FAL_KEY}")
    local ST; ST=$(echo "$POLL" | jq -r '.status // empty')
    if [ "$ST" = "COMPLETED" ]; then
      local R; R=$(curl -sS "$RESP_URL" -H "Authorization: Key ${FAL_KEY}")
      local URL; URL=$(echo "$R" | jq -r '.video.url // empty')
      if [ -n "$URL" ]; then curl -sSL "$URL" -o "$OUT"; return 0; fi
    fi
    [ "$ST" = "FAILED" ] || [ "$ST" = "ERROR" ] && { echo "  LTX failed: $POLL" >&2; return 1; }
  done
  echo "  LTX timeout" >&2; return 1
}

# ───────── Dispatch ─────────
case "$MODE" in
  plan)        do_plan ;;
  revise)      do_revise ;;
  produce)     do_produce ;;
  regen-scene) do_regen_scene ;;
  *) echo "ERROR: --mode must be plan|revise|produce|regen-scene" >&2; exit 1 ;;
esac
