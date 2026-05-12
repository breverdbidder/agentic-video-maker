# 🎬 agentic-video-maker

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Hebrew](https://img.shields.io/badge/RTL-עברית-blue)](#-עברית-hebrew)
[![Powered by](https://img.shields.io/badge/powered%20by-Gemini%20%2B%20ElevenLabs%20%2B%20fal.ai-success)](#credits)

> **AI video pipeline with a self-correcting critique loop.** From a one-line brief to a polished, captioned, narrated video — and an AI editor that iteratively improves it.

---

## 📥 Install

One-liner — clones the repo and installs node deps:

```bash
git clone https://github.com/Meir770ar/agentic-video-maker.git && cd agentic-video-maker/scripts && npm install
```

System dependencies (Debian/Ubuntu):

```bash
sudo apt install -y ffmpeg jq python3 fonts-heebo && npm install -g hyperframes
```

System dependencies (macOS):

```bash
brew install ffmpeg jq python3 && npm install -g hyperframes
```

Then copy `.env.example` to `.env`, fill in your API keys, and `source .env`.

---

## 🇮🇱 עברית (Hebrew)

### מה זה?

**agentic-video-maker** הוא pipeline שיוצר סרטון מקצועי מ-brief של שורה אחת — עם **לולאת ביקורת עצמית** שמשפרת את התוצר אוטומטית עד שהוא ברמת שיגור.

הצינור מחבר:
- **Gemini** — כותב את התסריט, יוצר prompts לוויזואלים, ומנתח את הסרטון הסופי כעורך וידאו בכיר
- **ElevenLabs** — קריינות איכותית (`eleven_v3`) + יצירת מוזיקה ב-Music API
- **fal.ai / xAI** — יצירת תמונות (FLUX, nano-banana 2) ווידאו (LTX-2, Grok Imagine)
- **HyperFrames + ffmpeg** — הרכבה, מעברים, כתוביות, גרפיקה אנימטיבית

תמיכה מלאה בעברית RTL (כתוביות, קריינות, פונטים).

### מה החידוש?

רוב כלי ה-AI video מסתיימים ב"יצרת ויזואל + voiceover". כאן נסגר הלולאה:

```
brief → תסריט → ויזואלים + קריינות + מוזיקה → הרכבה
                                                  ↓
                                  ניתוח Gemini Video (כמו עורך בכיר)
                                                  ↓
                                       הערות מובנות (JSON עם timestamps)
                                                  ↓
                                  patch אוטומטי ל-plan
                                                  ↓
                              render מחדש לסצנות שהושפעו
                                                  ↓
                                  (חוזר עד שהציון יעד הושג)
```

Gemini מחזיר תיקונים ספציפיים — "סצנה 2 קצרה מדי", "הטקסט קטן", "המוזיקה רועשת מדי בקריינות" — והסקריפט מחיל אותם ומפיק שוב, עד שהציון >= 8.5/10 או עד מקסימום 3 סבבים.

### התחלה מהירה (5 דקות)

1. **התקנה** — העתק את הפקודה למעלה
2. **מפתחות API** — `cp .env.example .env`, מלא את:
   - `GEMINI_API_KEY` ([ai.google.dev](https://aistudio.google.com))
   - `ELEVENLABS_API_KEY` ([elevenlabs.io](https://elevenlabs.io))
   - `FAL_KEY` ([fal.ai](https://fal.ai))
   - `VOICE_ID` (קול ציבורי מ-[Voice Library](https://elevenlabs.io/app/voice-library))
3. **תכנון** — `bash scripts/make-ai-video.sh --mode plan --brief "סרטון על בית קפה" --length 30 --quality medium --look warm --max-cost 5`
4. **הפקה עם auto-fix** — `bash scripts/make-ai-video.sh --mode produce --plan-id <ID> --critique-loop on`

### דגלים עיקריים

| דגל | מטרה |
|------|------|
| `--brief "<טקסט>"` | תיאור הסרטון בכל שפה |
| `--length N` | משך ביעד בשניות (10-60) |
| `--quality cheap\|medium\|premium\|ultra` | טיר איכות (משפיע על העלות) |
| `--look modern\|warm\|tech\|...` | סגנון ויזואלי |
| `--voice <id>` | קול ElevenLabs (חובה — אין default) |
| `--music-source musiclib\|elevenlabs\|auto` | מקור מוזיקה |
| `--critique on\|off` | ניתוח Gemini אחרי הפקה |
| `--critique-loop on` | לולאת תיקון עצמי |
| `--critique-target-score 8.5` | ציון יעד להפסיק |
| `--scene-source N:/path/file` | החלף סצנה N בקובץ שלך |
| `--img-model <m>` | בחירת מודל תמונה (ראה טבלה למטה) |
| `--vid-model <m>` | בחירת מודל וידאו (`ltx-2` / `grok-imagine`) |

### מודלים זמינים

**תמונות:**
- `flux-schnell` — fal.ai, ~$0.003, הכי מהיר וזול
- `flux-pro-1.1` — fal.ai, ~$0.04, איכות גבוהה
- `nano-banana-2` — Gemini 2.5 Flash Image, ~$0.039, ברירת מחדל טובה
- `nano-banana-pro` — **Imagen 4 Ultra**, ~$0.08, איכות פוטוריאליסטית פרימיום
- `gpt-image-1` — OpenAI GPT Image, ~$0.04 (דורש `OPENAI_API_KEY`)
- `imagen-3.0` — Imagen 3 (fallback)

**וידאו:**
- `ltx-2` — fal.ai, ~$0.07 ל-5 שניות, מהיר
- `grok-imagine` — xAI, ~$1.10 ל-5 שניות, פרימיום (דורש `XAI_API_KEY`)

### עלות

| איכות | תמונות | וידאו | סה"כ ל-60s |
|-------|--------|-------|-------------|
| cheap | FLUX schnell | LTX-2 | ~$0.50–1 |
| medium | nano-banana 2 | LTX-2 | ~$1.50–3 |
| premium | nano-banana 2 | Grok Imagine | ~$3–6 |
| ultra | A/B test images | Grok Imagine | ~$5–10 |

עם `--critique-loop on` × N סבבים: כפול כמות הסבבים בערך (סצנות מוכנות לא נוצרות מחדש).

---

## Why this exists

Most AI video tools stop at "generate visuals + voiceover". A real editor watches the result and fixes what's broken — pacing, text legibility, audio balance, music match. `agentic-video-maker` closes that loop:

```
brief → script → visuals + narration + music → compose
                                                  ↓
                                          Gemini Video critique
                                                  ↓
                                    structured editor notes (JSON)
                                                  ↓
                                          auto-patch plan
                                                  ↓
                                      re-render the affected scenes
                                                  ↓
                                          (loop until target)
```

---

## Quick start (5 minutes)

### 1. Install dependencies

```bash
# System
sudo apt install -y ffmpeg jq python3   # or brew install on macOS

# Node deps
cd scripts && npm install               # installs @google/genai for the critique helper

# Optional but recommended
npm install -g hyperframes               # for animated text overlays
```

### 2. Set environment variables

Copy `.env.example` → `.env` and fill in:

```bash
GEMINI_API_KEY=...        # https://aistudio.google.com
ELEVENLABS_API_KEY=...    # https://elevenlabs.io
FAL_KEY=...               # https://fal.ai
VOICE_ID=...              # Pick any voice from https://elevenlabs.io/app/voice-library
```

Then `source .env` (or use a tool like `direnv`).

### 3. Plan a video

```bash
bash scripts/make-ai-video.sh \
  --mode plan \
  --brief "30-second promo for a boutique coffee shop opening downtown, cozy winter aesthetic, no people" \
  --length 30 \
  --quality medium \
  --look warm \
  --aspects 16:9 \
  --max-cost 5
```

Output: `PLAN_ID: p_...` plus a preview (title, narration, scenes, music mood, estimated cost).

### 4. Produce — with the self-correcting loop

```bash
bash scripts/make-ai-video.sh \
  --mode produce \
  --plan-id <PLAN_ID> \
  --critique-loop on \
  --critique-target-score 8.5 \
  --critique-max-rounds 3
```

The pipeline will:
1. Generate scene assets (AI images or videos)
2. Synthesize narration
3. Compose music (ElevenLabs) and SFX
4. Burn captions, motion graphics, intro/outro
5. **Run Gemini Video critique** on the final mp4
6. Parse structured editor notes (`plan_patch` hints with timestamp + severity)
7. **Auto-apply patches** to the plan (duration tweaks, text changes, audio rebalance, font scale, position)
8. Re-render the affected scenes
9. Repeat until target score reached or max rounds hit

Final video lands at `/tmp/ai-video-result-<PLAN_ID>.mp4`. Critique JSON next to it.

---

## How the self-correcting loop works

After produce, [`gemini-critique.cjs`](scripts/gemini-critique.cjs) uploads the mp4 to Gemini, asks a senior-editor critique with this schema:

```json
{
  "overall_score": 7,
  "summary": "...",
  "strengths": [...],
  "issues": [
    {
      "scene_index": 2,
      "timestamp": "00:08-00:12",
      "severity": "P0|P1|P2",
      "category": "pacing|color|audio|text|narrative|transition|music|sfx",
      "problem": "Hebrew caption disappears too fast",
      "fix": "Extend display duration by 1.5s for RTL reading time",
      "plan_patch": { "field": "scenes[1].duration_sec", "new_value": 6 }
    }
  ],
  "missing_beats": [...],
  "ready_to_ship": false
}
```

Then [`patch-plan.cjs`](scripts/patch-plan.cjs) applies each `plan_patch` (parses dotted/indexed paths like `scenes[2].duration_sec` or `text_style.font_size_multiplier`), marks affected scenes as `pending`, and the pipeline re-renders.

### Patchable fields

| Field | Type | Effect |
|-------|------|--------|
| `scenes[N].duration_sec` | number | Extend/shorten a scene |
| `scenes[N].text_on_screen` | string | Change overlay text |
| `scenes[N].text_position` | enum | `bottom-center` \| `lower-third` \| `top-center` \| `center` |
| `scenes[N].ken_burns` | enum | `zoom_in_center` \| `zoom_out_center` \| `pan_left/right/up` |
| `scenes[N].image_prompt` | string | Refine visual prompt (triggers asset regen) |
| `text_style.font_size_multiplier` | number 0.7–2.0 | Scale caption font globally |
| `text_style.position` | enum | Global caption position |
| `audio_mix.narration_volume` | number | Voice gain (default 1.25) |
| `audio_mix.music_volume` | number | Music gain (default 0.18) |
| `music_mood` | string | Comma-separated mood tags |
| `title` / `subtitle` / `outro` | string | Top-level text |

---

## Pipeline overview

| Phase | Step | Tool |
|-------|------|------|
| 1 | Brief → Hebrew/English script + scene plan + music mood | Gemini 2.5 Flash |
| 2 | Per-scene visual prompts formatted per generator model | Gemini 2.5 Flash |
| 3 | Visual generation | fal.ai (FLUX schnell / nano-banana 2 / LTX-2) or xAI (Grok Imagine) |
| 4 | Narration | ElevenLabs `eleven_v3` (Hebrew-capable) |
| 5 | Music | ElevenLabs Music API (instrumental, prompt-driven) — or local lib if available |
| 6 | Word-level transcription for caption sync | Gemini audio |
| 7 | ffmpeg compose: clips + Ken Burns + grade + captions + motion graphics + intro/outro | ffmpeg + HyperFrames |
| 8 | Audio mix: amix with optional sidechain duck | ffmpeg |
| 9 | (optional) Gemini Video critique | Gemini 2.5 Flash |
| 10 | (optional) Auto-patch plan + re-render loop | this repo |
| 11 | Final encode (WhatsApp-safe H.264 baseline + AAC) | ffmpeg |

---

## All flags

| Flag | Default | Purpose |
|------|---------|---------|
| `--mode` | required | `plan` \| `revise` \| `produce` \| `regen-scene` |
| `--brief` | — | Free-form video brief (any language) |
| `--plan-id` | — | Operate on an existing plan |
| `--feedback` | — | Revision notes (with `--mode revise`) |
| `--scene` | — | Scene index for `--mode regen-scene` |
| `--length` | 30 | Target duration in seconds |
| `--quality` | medium | `cheap` \| `medium` \| `premium` \| `ultra` |
| `--look` | classic | `modern` \| `warm` \| `tech` \| `luxury` \| `minimal` \| `medical` \| `documentary` \| `cinematic` \| `classic` \| `neon` |
| `--aspects` | 16:9 | `16:9` \| `9:16` \| `1:1` (comma-separated for multi-output) |
| `--max-cost` | 10 | Abort produce if estimated cost exceeds USD |
| `--brand` | — | Brand label shown on outro card |
| `--end-logo` | — | PNG path for end-card logo |
| `--captions` | on | Burn word-sync captions |
| `--allowed-religious-context` | none | Relax religious-imagery safety for a specific context |
| `--voice` | $VOICE_ID env | ElevenLabs voice ID |
| `--music-source` | auto | `musiclib` \| `elevenlabs` \| `auto` |
| `--music-prompt` | derived | Custom ElevenLabs Music prompt |
| `--critique` | off | Generate critique JSON after produce |
| `--critique-loop` | off | Auto-apply patches + re-render |
| `--critique-target-score` | 8.5 | Stop loop when score ≥ N |
| `--critique-max-rounds` | 3 | Hard cap on iterations |
| `--scene-source N:path` | — | Substitute scene N with an existing image/video file. Repeatable. |
| `--img-model <m>` | by `--quality` tier | `flux-schnell` \| `flux-pro-1.1` \| `nano-banana-2` \| `nano-banana-pro` \| `gpt-image-1` \| `imagen-3.0` |
| `--vid-model <m>` | by `--quality` tier | `ltx-2` \| `grok-imagine` |

### Available generators

**Image models:**

| Model | Provider | Cost/image | Notes |
|-------|----------|------------|-------|
| `flux-schnell` | fal.ai | ~$0.003 | Fastest, lowest cost |
| `flux-pro-1.1` | fal.ai | ~$0.04 | Better quality |
| `nano-banana-2` | Google (Gemini 2.5 Flash Image) | ~$0.039 | Good default |
| `nano-banana-pro` | Google (Imagen 4 Ultra) | ~$0.08 | Premium quality, photoreal |
| `gpt-image-1` | OpenAI | ~$0.04 | Requires `OPENAI_API_KEY` |
| `imagen-3.0` | Google | ~$0.04 | Imagen 3 fallback |

**Video models:**

| Model | Provider | Cost/5s | Notes |
|-------|----------|---------|-------|
| `ltx-2` | fal.ai | ~$0.07 | Fast, default for cheap/medium |
| `grok-imagine` | xAI | ~$1.10 | Premium, requires `XAI_API_KEY` |

### Pick a model explicitly

```bash
# Use Imagen 4 Ultra for images + Grok for video, regardless of quality tier
bash scripts/make-ai-video.sh --mode produce --plan-id <ID> \
  --img-model nano-banana-pro \
  --vid-model grok-imagine
```

### Use your own footage

```bash
bash scripts/make-ai-video.sh --mode produce --plan-id <PLAN_ID> \
  --scene-source 1:/path/to/my-hero-shot.jpg \
  --scene-source 4:/path/to/my-product-demo.mp4
```

The pipeline will skip AI generation for those scenes and use your files instead.

---

## Quality tiers + cost

Estimated cost per 60s video with 8 scenes (visuals + narration + music + captions + critique). Actual cost depends on your provider pricing.

| Quality | Images | Videos | Total/run |
|---------|--------|--------|-----------|
| cheap | FLUX schnell | LTX-2 | ~$0.50–1 |
| medium | nano-banana 2 | LTX-2 | ~$1.50–3 |
| premium | nano-banana 2 | Grok Imagine | ~$3–6 |
| ultra | nano-banana 2 (A/B test) | Grok Imagine | ~$5–10 |

With `--critique-loop on`, multiply by the number of rounds (each re-render is roughly the same cost; cached scenes don't regenerate).

---

## Optional: fonts

Captions and motion graphics work out of the box with **Heebo** (free, Google Fonts, supports Hebrew). To install on Debian/Ubuntu:

```bash
sudo apt install fonts-heebo
fc-cache -fv
```

For other fonts, set env vars:

```bash
export CAPTION_FONT_NAME="Open Sans"           # fontconfig family name
export TITLE_FONT_FILE="/path/to/title.otf"    # used for intro/outro cards
export FONT_HEAVY="/path/to/bold.otf"          # motion graphics heavy
export FONT_BOLD="/path/to/bold.otf"           # motion graphics bold
export FONT_LIGHT="/path/to/light.otf"         # motion graphics light
export FONT_SERIF="/path/to/serif.otf"         # motion graphics serif
```

Any unset font falls back to a browser default (still works, less polished).

---

## Architecture

```
make-ai-video.sh     ← main bash orchestrator
  ├── do_plan        ← Gemini Director → plan JSON
  ├── do_revise      ← merge user feedback into plan
  ├── do_produce     ← critique loop wrapper around produce_pipeline
  └── do_regen_scene ← regenerate one scene only

  produce_pipeline:
    1. narrate (ElevenLabs)
    2. apply --scene-source overrides
    3. generate scene assets (fal.ai / xAI)
    4. normalize + Ken Burns
    5. transcribe → ASS captions
    6. burn captions + brand badge
    7. intro/outro + end-logo
    8. music + audio mix
    9. (if --critique on) gemini-critique.cjs → critique.json

gemini-critique.cjs  ← upload mp4 to Gemini Files API, fetch structured critique
patch-plan.cjs       ← parse critique.plan_patch hints, apply to plan JSON
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `ERROR: voice ID required` | `$VOICE_ID` env not set | Set `VOICE_ID` or pass `--voice <id>` |
| `jq: command not found` | jq missing | `apt install jq` |
| `hyperframes: command not found` | not on PATH | `npm install -g hyperframes`; check `$HOME/.npm-global/bin` is on PATH |
| Captions show as gibberish | libass can't find a Hebrew-capable font | Install Heebo or set `$CAPTION_FONT_NAME` to a font that's installed |
| MG render fails silently | Hebrew fonts missing for HyperFrames | Set `$FONT_HEAVY` / `$FONT_LIGHT` / etc to OTFs with Hebrew glyphs |
| Critique returns score=0 / parse error | Gemini API key invalid or quota exhausted | Verify `$GEMINI_API_KEY`; check quota at ai.dev |
| Produce aborts: cost exceeds max | Estimate > `--max-cost` | Raise `--max-cost` or pick cheaper `--quality` |

---

## Credits

Built by orchestrating:

- [Google Gemini](https://ai.google.dev) — Director, Prompt Engineer, transcription, Video critique
- [ElevenLabs](https://elevenlabs.io) — narration (`eleven_v3`) + Music API
- [fal.ai](https://fal.ai) — FLUX schnell, nano-banana 2, LTX-2
- [xAI](https://x.ai/api) — Grok Imagine (premium tier)
- [HyperFrames](https://github.com/anthropics/hyperframes) — HTML-based motion graphics
- [ffmpeg](https://ffmpeg.org) — composition + encoding
- [whisper-local](https://github.com/openai/whisper) (optional fallback) — transcription

This repo doesn't introduce new models — it's an orchestration layer with a self-correcting feedback loop.

---

## License

MIT — see [LICENSE](LICENSE).

Contributions, issues, and forks welcome.
