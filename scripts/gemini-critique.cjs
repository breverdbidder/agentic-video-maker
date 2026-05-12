#!/usr/bin/env node
// gemini-critique.cjs — Gemini Video critique for ai-video (CommonJS so it can use NODE_PATH)
// Usage: node gemini-critique.cjs <video_path> <brief_text> <output_json_path> [plan_path]
//
// If plan_path is provided, the plan JSON schema is given to Gemini so plan_patch
// suggestions reference fields that actually exist.

const { GoogleGenAI } = require('@google/genai');
const fs = require('node:fs');

const [,, videoPath, briefText, outPath, planPath] = process.argv;
if (!videoPath || !briefText || !outPath) {
  console.error('Usage: gemini-critique.cjs <video_path> <brief_text> <output_json_path> [plan_path]');
  process.exit(1);
}
if (!fs.existsSync(videoPath)) {
  console.error('Video not found:', videoPath);
  process.exit(1);
}

const KEY = process.env.GEMINI_API_KEY || process.env.GEMINI_API_KEY_FREE;
if (!KEY) { console.error('GEMINI_API_KEY missing'); process.exit(1); }

const MODEL = process.env.GEMINI_CRITIQUE_MODEL || 'gemini-2.5-flash';
const ai = new GoogleGenAI({ apiKey: KEY });

const SYSTEM_PROMPT = `You are a senior video editor at a top-tier post-production studio. Review the video as if reviewing for a paying client. Return ONLY valid JSON, no prose, no markdown fences.

SCHEMA:
{
  "overall_score": <number 1-10>,
  "summary": "<one-line gut reaction>",
  "strengths": ["<bullet>", ...],
  "issues": [
    {
      "scene_index": <number, best guess of which scene 1-N, or 0 if global>,
      "timestamp": "<MM:SS or MM:SS-MM:SS>",
      "severity": "P0|P1|P2",
      "category": "pacing|color|audio|text|narrative|transition|music|sfx|overall",
      "problem": "<what is wrong>",
      "fix": "<actionable: what an editor would do, in 1 sentence>",
      "plan_patch": {
        "field": "<which plan JSON field to change, e.g. scenes[3].duration_sec, music_mood, scenes[2].text_on_screen>",
        "new_value": "<proposed new value>"
      }
    }
  ],
  "missing_beats": ["<thing the video should have but doesn't>", ...],
  "ready_to_ship": <boolean>
}

SEVERITY:
- P0: blocking — must fix before delivery (broken audio, missing scene, illegible text, narrative gap)
- P1: noticeable problem that hurts perception (awkward pacing, color mismatch, weak music transition)
- P2: polish-level (could be better but not blocking)

EVALUATE: pacing, color consistency, audio mix (narration vs music balance), text legibility and animation, narrative arc, transitions, music-mood match, sfx placement, intro/outro impact.
For Hebrew text overlays, account for RTL reading time — Hebrew typically needs 20-30% longer on-screen than English.

PLAN_PATCH RULES (CRITICAL):
- plan_patch.field MUST reference a path that exists (or has a default) in the plan schema below.
- ONLY patch these field types (anything else will be SKIPPED by the patcher):

  Per-scene fields (under scenes[N]):
  * scenes[N].duration_sec (number) — extend/shorten a scene
  * scenes[N].text_on_screen (string or null) — change text content (preserve Hebrew; never null if scene previously had text)
  * scenes[N].text_position (string) — one of: bottom-center, top-center, lower-third, center
  * scenes[N].ken_burns (string) — one of: zoom_in_center, zoom_out_center, pan_left, pan_right, pan_up
  * scenes[N].image_prompt (string) — refine visual prompt (will trigger asset regen)

  Global text styling (text_style root — defaults exist if not in plan):
  * text_style.font_size_multiplier (number 0.7-2.0, default 1.0) — scale caption font size
  * text_style.position (string, default "bottom-center") — global caption position: bottom-center, lower-third, top-center, center

  Global audio mix (audio_mix root — defaults exist if not in plan):
  * audio_mix.narration_volume (number, default 1.25) — voice gain (1.0=neutral, 1.5=louder)
  * audio_mix.music_volume (number, default 0.18) — music gain (0.10=ducked more, 0.25=more music)

  Top-level strings:
  * music_mood (string, comma-separated tags)
  * title (string) / subtitle (string) / outro (string)

- DO NOT invent fields outside this list (e.g. text_on_screen[].duration_sec, audio_mix.music_volume_during_narration). Those will be skipped.
- Omit plan_patch entirely if no field above applies. The critique text alone is still valuable.`;

async function pollOnce(fileName) {
  for (let a = 0; a < 5; a++) {
    try { return await ai.files.get({ name: fileName }); }
    catch (e) {
      if (e.status === 503 || e.status === 500) { await new Promise(r => setTimeout(r, 2000*(a+1))); continue; }
      throw e;
    }
  }
  throw new Error('Repeated 5xx');
}

(async () => {
  try {
    console.error(`[critique] uploading ${videoPath}...`);
    const t0 = Date.now();
    const uploaded = await ai.files.upload({
      file: videoPath,
      config: { mimeType: 'video/mp4', displayName: 'critique-target.mp4' }
    });
    console.error(`[critique] uploaded ${uploaded.name} (${((Date.now()-t0)/1000).toFixed(1)}s)`);

    let file = uploaded;
    let waited = 0;
    while (file.state !== 'ACTIVE') {
      if (file.state === 'FAILED') throw new Error('Gemini file processing failed');
      await new Promise(r => setTimeout(r, 5000));
      waited += 5;
      file = await pollOnce(uploaded.name);
      if (waited > 600) throw new Error('Timeout waiting for ACTIVE');
    }
    console.error(`[critique] processed (${waited}s), querying ${MODEL}...`);

    // Optionally include current plan schema so Gemini's plan_patch suggestions hit real fields
    let planSection = '';
    if (planPath && fs.existsSync(planPath)) {
      try {
        const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
        // Slim down the plan to a representative subset (avoid sending huge prompts)
        const slim = {
          title: plan.title, subtitle: plan.subtitle, outro: plan.outro,
          narration: plan.narration, music_mood: plan.music_mood,
          scenes: (plan.scenes || []).map(s => ({
            i: s.i, type: s.type, duration_sec: s.duration_sec,
            ken_burns: s.ken_burns, text_on_screen: s.text_on_screen,
            text_position: s.text_position, image_prompt: (s.image_prompt || '').slice(0, 200)
          }))
        };
        planSection = `\n\nPLAN JSON (the structure your plan_patch fields must reference):\n${JSON.stringify(slim, null, 2)}\n`;
      } catch (e) { console.error('[critique] failed to read plan for prompt:', e.message); }
    }

    const t1 = Date.now();
    const resp = await ai.models.generateContent({
      model: MODEL,
      contents: [{
        role: 'user',
        parts: [
          { fileData: { mimeType: 'video/mp4', fileUri: file.uri } },
          { text: `Brief context: ${briefText}${planSection}\n\nGive the full critique JSON now.` }
        ]
      }],
      config: {
        systemInstruction: SYSTEM_PROMPT,
        temperature: 0.3,
        responseMimeType: 'application/json',
      }
    });
    console.error(`[critique] response (${((Date.now()-t1)/1000).toFixed(1)}s)`);

    const raw = resp.text;
    const parsed = JSON.parse(raw);
    fs.writeFileSync(outPath, JSON.stringify(parsed, null, 2));
    console.error(`[critique] saved → ${outPath}`);

    const p0 = (parsed.issues || []).filter(i => i.severity === 'P0').length;
    const p1 = (parsed.issues || []).filter(i => i.severity === 'P1').length;
    const p2 = (parsed.issues || []).filter(i => i.severity === 'P2').length;
    console.log(`score=${parsed.overall_score} ready=${parsed.ready_to_ship} P0=${p0} P1=${p1} P2=${p2}`);

    try { await ai.files.delete({ name: uploaded.name }); } catch (e) { console.error('[critique] cleanup failed:', e.message); }
    process.exit(0);
  } catch (e) {
    console.error('[critique] ERROR:', e.message);
    process.exit(1);
  }
})();
