#!/usr/bin/env node
// patch-plan.cjs — Apply Gemini critique plan_patch hints to plan JSON
// Usage: node patch-plan.cjs <plan.json> <critique.json> <output_plan.json>
// Output (stdout JSON): { applied: [...], skipped: [...], scenes_to_regen: [...] }
// Exit 0 if any patches applied, 1 if none/all skipped.

const fs = require('node:fs');

const [,, planPath, critiquePath, outPath] = process.argv;
if (!planPath || !critiquePath || !outPath) {
  console.error('Usage: patch-plan.cjs <plan.json> <critique.json> <output_plan.json>');
  process.exit(2);
}

function safeReadJson(p, label) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    console.error(`ERROR: ${label} not readable as JSON: ${p} — ${e.message}`);
    process.exit(2);
  }
}
const plan = safeReadJson(planPath, 'plan');
const critique = safeReadJson(critiquePath, 'critique');

// Parse a field path like "scenes[0].text_on_screen.duration_sec" → ["scenes", 0, "text_on_screen", "duration_sec"]
function parsePath(s) {
  const parts = [];
  const tokens = s.split('.');
  for (const tok of tokens) {
    const m = tok.match(/^([a-zA-Z_][a-zA-Z0-9_]*)((?:\[\d+\])*)$/);
    if (!m) return null;
    parts.push(m[1]);
    const idx = m[2];
    if (idx) {
      const nums = [...idx.matchAll(/\[(\d+)\]/g)].map(x => parseInt(x[1], 10));
      parts.push(...nums);
    }
  }
  return parts;
}

function pathExists(obj, parts) {
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    const k = parts[i];
    if (cur === null || cur === undefined) return false;
    if (typeof cur !== 'object') return false;
    cur = cur[k];
  }
  return cur !== null && cur !== undefined && typeof cur === 'object';
}

// Whitelist of root-creatable patch paths — defaults exist downstream even if plan lacks them.
// These are auto-materialized so plans don't need to pre-declare every setting.
const AUTO_CREATE_ROOTS = new Set(['text_style', 'audio_mix']);

function ensurePathParent(obj, parts) {
  if (parts.length < 2) return true;
  const root = parts[0];
  if (!AUTO_CREATE_ROOTS.has(root)) return false;
  if (!obj[root] || typeof obj[root] !== 'object') obj[root] = {};
  return true;
}

function setPath(obj, parts, value) {
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    cur = cur[parts[i]];
  }
  cur[parts[parts.length - 1]] = value;
}

// Coerce string values like "2.5" → 2.5, "true" → true, etc.
function coerce(v) {
  if (typeof v !== 'string') return v;
  if (v === 'true') return true;
  if (v === 'false') return false;
  if (/^-?\d+$/.test(v)) return parseInt(v, 10);
  if (/^-?\d*\.\d+$/.test(v)) return parseFloat(v);
  return v;
}

const applied = [];
const skipped = [];
const scenesToRegen = new Set();

for (const issue of (critique.issues || [])) {
  const patch = issue.plan_patch;
  if (!patch || !patch.field) {
    skipped.push({ reason: 'no plan_patch', issue: issue.problem });
    continue;
  }
  const parts = parsePath(patch.field);
  if (!parts) {
    skipped.push({ reason: 'unparseable path', field: patch.field });
    continue;
  }
  // Check parent exists (so the leaf field can be set). Whitelisted roots are auto-created.
  if (!pathExists(plan, parts)) {
    if (!ensurePathParent(plan, parts)) {
      skipped.push({ reason: 'path not in plan', field: patch.field });
      continue;
    }
  }
  // Apply
  try {
    const newVal = coerce(patch.new_value);
    setPath(plan, parts, newVal);
    applied.push({ field: patch.field, new_value: newVal, problem: issue.problem });

    // If patch is inside scenes[N], mark that scene for regen
    if (parts[0] === 'scenes' && typeof parts[1] === 'number') {
      // parts[1] is array index; convert to scene .i value (1-based)
      const sceneArrayIdx = parts[1];
      if (plan.scenes && plan.scenes[sceneArrayIdx]) {
        const sceneI = plan.scenes[sceneArrayIdx].i;
        if (sceneI) scenesToRegen.add(sceneI);
      }
    }
  } catch (e) {
    skipped.push({ reason: 'set failed: ' + e.message, field: patch.field });
  }
}

// Reset status on scenes that need re-gen
for (const i of scenesToRegen) {
  const scene = (plan.scenes || []).find(s => s.i === i);
  if (scene) {
    scene.status = 'pending';
    delete scene.asset_path;
  }
}

fs.writeFileSync(outPath, JSON.stringify(plan, null, 2));

const result = {
  applied,
  skipped,
  scenes_to_regen: [...scenesToRegen],
  total_applied: applied.length,
  total_skipped: skipped.length
};
console.log(JSON.stringify(result, null, 2));
process.exit(applied.length > 0 ? 0 : 1);
