# ============================================================================
# scaffold-part2.ps1 — Writes the remaining src/ files:
#   guardrailValidator.ts, llmInterpreter.ts, optimizer.ts,
#   finalValidator.ts, responseBuilder.ts, index.ts
# Also writes wrangler.jsonc, package.json, tsconfig.json, README.md
# and a .gitignore.
# ============================================================================

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
$SrcDir = Join-Path $ProjectRoot "src"

if (-not (Test-Path $SrcDir)) {
    New-Item -ItemType Directory -Path $SrcDir | Out-Null
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    Write-Host "  wrote $Path" -ForegroundColor Green
}

# ============================================================================
# src/guardrailValidator.ts
# ============================================================================
$guardrailValidatorTs = @'
// ============================================================================
// src/guardrailValidator.ts — Deterministic validator for LLM directive output.
// Enforces: LENGTH CHECK, BOOLEAN INVARIANTS, hours uniqueness/ascending/range,
// factor range, structured_adjustment shape.
// ============================================================================

import {
  DirectiveEntry,
  DirectiveType,
  LLMDirectiveResponse,
} from "./types";

export interface GuardrailContext {
  notes_count: number;
}

export interface GuardrailResult {
  ok: boolean;
  errors: string[];
}

const VALID_DIRECTIVE_TYPES: DirectiveType[] = [
  "solar_reduction",
  "minimum_battery_reserve",
  "no_charge_window",
  "no_discharge_window",
  "max_grid_window",
  "no_op",
];

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isFiniteNumber(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function checkHours(
  hours: unknown,
  errors: string[],
  label: string
): hours is number[] {
  if (!Array.isArray(hours)) {
    errors.push(`${label}: 'hours' must be an array of integers.`);
    return false;
  }
  if (hours.length === 0) {
    errors.push(`${label}: 'hours' must be a non-empty array.`);
    return false;
  }
  const seen = new Set<number>();
  let prev = -1;
  for (let i = 0; i < hours.length; i++) {
    const h = hours[i];
    if (typeof h !== "number" || !Number.isInteger(h) || h < 0 || h > 23) {
      errors.push(
        `${label}: hours[${i}]=${String(h)} must be an integer in 0..23.`
      );
      return false;
    }
    if (seen.has(h)) {
      errors.push(`${label}: hours contains duplicate value ${h}.`);
      return false;
    }
    if (h <= prev) {
      errors.push(
        `${label}: hours must be strictly ascending (got [${hours.join(",")}]).`
      );
      return false;
    }
    seen.add(h);
    prev = h;
  }
  return true;
}

function validateStructuredAdjustment(
  entry: DirectiveEntry,
  idx: number,
  errors: string[]
): void {
  const label = `Entry ${idx} (directive_type='${String(entry.directive_type)}')`;
  const adj = entry.structured_adjustment;

  switch (entry.directive_type) {
    case "solar_reduction": {
      if (!isPlainObject(adj)) {
        errors.push(
          `${label}: structured_adjustment must be an object with {hours, factor}.`
        );
        return;
      }
      checkHours(adj.hours, errors, `${label}.structured_adjustment`);
      if (!isFiniteNumber(adj.factor) || adj.factor <= 0 || adj.factor > 1) {
        errors.push(
          `${label}: factor must satisfy 0 < factor <= 1 (got ${String(
            adj.factor
          )}). Remember: factor = FRACTION REMAINING.`
        );
      }
      return;
    }
    case "minimum_battery_reserve": {
      if (!isPlainObject(adj)) {
        errors.push(
          `${label}: structured_adjustment must be an object with {hours, minimum_energy_kwh}.`
        );
        return;
      }
      checkHours(adj.hours, errors, `${label}.structured_adjustment`);
      if (
        !isFiniteNumber(adj.minimum_energy_kwh) ||
        adj.minimum_energy_kwh < 0
      ) {
        errors.push(
          `${label}: minimum_energy_kwh must be a finite number >= 0 (got ${String(
            adj.minimum_energy_kwh
          )}).`
        );
      }
      return;
    }
    case "no_charge_window":
    case "no_discharge_window": {
      if (!isPlainObject(adj)) {
        errors.push(
          `${label}: structured_adjustment must be an object with {hours}.`
        );
        return;
      }
      checkHours(adj.hours, errors, `${label}.structured_adjustment`);
      return;
    }
    case "max_grid_window": {
      if (!isPlainObject(adj)) {
        errors.push(
          `${label}: structured_adjustment must be an object with {hours, max_grid_kwh}.`
        );
        return;
      }
      checkHours(adj.hours, errors, `${label}.structured_adjustment`);
      if (!isFiniteNumber(adj.max_grid_kwh) || adj.max_grid_kwh < 0) {
        errors.push(
          `${label}: max_grid_kwh must be a finite number >= 0 (got ${String(
            adj.max_grid_kwh
          )}).`
        );
      }
      return;
    }
    case "no_op": {
      if (adj !== null) {
        errors.push(
          `${label}: directive_type='no_op' but structured_adjustment !== null. For no_op, structured_adjustment MUST be null.`
        );
      }
      return;
    }
    default: {
      errors.push(
        `${label}: unknown directive_type. Must be one of: ${VALID_DIRECTIVE_TYPES.join(
          ", "
        )}.`
      );
      return;
    }
  }
}

export function validateDirectiveOutput(
  parsed: LLMDirectiveResponse,
  ctx: GuardrailContext
): GuardrailResult {
  const errors: string[] = [];
  const entries = parsed.directive_interpretation;

  if (!Array.isArray(entries)) {
    return {
      ok: false,
      errors: ["directive_interpretation must be an array."],
    };
  }

  if (entries.length !== ctx.notes_count) {
    errors.push(
      `directive_interpretation.length MUST exactly equal operator_notes.length (expected ${ctx.notes_count}, got ${entries.length}). Re-emit the FULL JSON with exactly ${ctx.notes_count} entries.`
    );
  }

  for (let i = 0; i < entries.length; i++) {
    const raw = entries[i] as unknown;
    if (!isPlainObject(raw)) {
      errors.push(`Entry ${i} must be an object.`);
      continue;
    }

    const entry = raw as unknown as DirectiveEntry;

    if (
      !isFiniteNumber(entry.note_index) ||
      !Number.isInteger(entry.note_index)
    ) {
      errors.push(
        `Entry ${i}: note_index must be an integer (got ${String(
          entry.note_index
        )}).`
      );
    }

    if (
      typeof entry.directive_type !== "string" ||
      !VALID_DIRECTIVE_TYPES.includes(entry.directive_type)
    ) {
      errors.push(
        `Entry ${i}: directive_type must be one of: ${VALID_DIRECTIVE_TYPES.join(
          ", "
        )} (got ${String(entry.directive_type)}).`
      );
      continue;
    }

    if (typeof entry.applies !== "boolean") {
      errors.push(
        `Entry ${i}: applies must be a boolean (got ${String(entry.applies)}).`
      );
    } else {
      if (entry.directive_type !== "no_op" && entry.applies === false) {
        errors.push(
          `Entry ${i} has directive_type='${entry.directive_type}' but applies=false. For non-no_op, applies MUST be true. Re-emit the full JSON.`
        );
      }
      if (entry.directive_type === "no_op" && entry.applies === true) {
        errors.push(
          `Entry ${i} has directive_type='no_op' but applies=true. For no_op, applies MUST be false. Re-emit the full JSON.`
        );
      }
    }

    if (entry.directive_type === "no_op" && entry.structured_adjustment !== null) {
      errors.push(
        `Entry ${i}: directive_type='no_op' but structured_adjustment is not null. Set structured_adjustment to null.`
      );
    }
    if (
      entry.directive_type !== "no_op" &&
      (entry.structured_adjustment === null ||
        entry.structured_adjustment === undefined)
    ) {
      errors.push(
        `Entry ${i}: directive_type='${entry.directive_type}' but structured_adjustment is null. For non-no_op directives, structured_adjustment MUST be populated.`
      );
    }

    if (
      typeof entry.explanation !== "string" ||
      entry.explanation.trim().length === 0
    ) {
      errors.push(`Entry ${i}: explanation must be a non-empty string.`);
    }

    validateStructuredAdjustment(entry, i, errors);
  }

  return { ok: errors.length === 0, errors };
}
'@
Write-Utf8NoBom -Path (Join-Path $SrcDir "guardrailValidator.ts") -Content $guardrailValidatorTs

# ============================================================================
# src/llmInterpreter.ts
# ============================================================================
$llmInterpreterTs = @'
// ============================================================================
// src/llmInterpreter.ts — LLM directive interpreter.
//   Primary: Gemini (gemini-1.5-flash, fallback to gemini-2.0-flash-exp)
//   Fallback: OpenAI gpt-4o-mini
// ============================================================================

import {
  ApiError,
  DirectiveEntry,
  Env,
  LLMCallResult,
  LLMDirectiveResponse,
  OptimizeRequest,
} from "./types";
import {
  GuardrailContext,
  GuardrailResult,
  validateDirectiveOutput,
} from "./guardrailValidator";

const REQUEST_TIMEOUT_MS = 5000;
const GEMINI_MODEL_PRIMARY = "gemini-1.5-flash";
const GEMINI_MODEL_FALLBACK = "gemini-2.0-flash-exp";
const OPENAI_MODEL = "gpt-4o-mini";

export function stripMarkdownWrappers(raw: string): string {
  let s = raw.trim();
  s = s.replace(/^```(?:json)?\s*/i, "");
  s = s.replace(/\s*```$/i, "");
  s = s.trim();
  s = s.replace(/^`+|`+$/g, "").trim();
  return s;
}

export function parseLLMJson(raw: string): LLMDirectiveResponse {
  const cleaned = stripMarkdownWrappers(raw);
  let parsed: unknown;
  try {
    parsed = JSON.parse(cleaned);
  } catch {
    throw new Error("llm_json_parse_failed");
  }
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    !Array.isArray((parsed as { directive_interpretation?: unknown }).directive_interpretation)
  ) {
    throw new Error("llm_json_shape_invalid");
  }
  return parsed as LLMDirectiveResponse;
}

const SYSTEM_PROMPT = `You are a directive extractor. Output ONLY a JSON object: {'directive_interpretation': [ ...entries... ]}. 
Time windows: start INCLUSIVE, end EXCLUSIVE. 
'factor' = fraction REMAINING. 
applies=true for non-no_op, false for no_op. hours: unique 0..23 ascending. 
Do NOT invent values. Do NOT output a schedule.

Examples:
1. 'Solar output will drop to about 20% from 1 PM to 3 PM.' -> solar_reduction, hours=[13,14], factor=0.2
2. 'Expect an 80% reduction in rooftop solar during the 1-3 PM window.' -> solar_reduction, hours=[13,14], factor=0.2
3. 'Do not charge the battery between 2 PM and 4 PM.' -> no_charge_window, hours=[14,15]
4. 'Keep at least 120 kWh in reserve from 6 PM until 9 PM.' -> minimum_battery_reserve, hours=[18,19,20], minimum_energy_kwh=120
5. 'The cafeteria menu changes tomorrow.' -> no_op, applies=false, structured_adjustment=null`;

export interface PromptContext {
  peak_tariff_hours: number[];
  battery_capacity_kwh: number;
  initial_energy_kwh: number;
}

export function computePromptContext(req: OptimizeRequest): PromptContext {
  const sorted = [...req.hours].sort((a, b) => {
    if (b.tariff_bdt_per_kwh !== a.tariff_bdt_per_kwh) {
      return b.tariff_bdt_per_kwh - a.tariff_bdt_per_kwh;
    }
    return a.hour - b.hour;
  });
  const peak = sorted.slice(0, 4).map((h) => h.hour).sort((a, b) => a - b);
  return {
    peak_tariff_hours: peak,
    battery_capacity_kwh: req.battery.capacity_kwh,
    initial_energy_kwh: req.battery.initial_energy_kwh,
  };
}

function buildUserMessage(
  req: OptimizeRequest,
  ctx: PromptContext,
  corrective?: string
): string {
  const notesList = req.operator_notes
    .map((n, i) => `  ${i}: ${JSON.stringify(n)}`)
    .join("\n");

  const base = `Operator notes (indexed from 0):
${notesList}

Context:
- Top 4 peak tariff hours (0-23): [${ctx.peak_tariff_hours.join(", ")}]
- Battery capacity_kwh: ${ctx.battery_capacity_kwh}
- Battery initial_energy_kwh: ${ctx.initial_energy_kwh}

Return exactly ${req.operator_notes.length} entr${
    req.operator_notes.length === 1 ? "y" : "ies"
  } in directive_interpretation, with note_index values 0..${
    req.operator_notes.length - 1
  }, in order. Each entry must have: note_index, applies, directive_type, structured_adjustment, explanation.`;

  if (corrective) {
    return `${base}

CORRECTIVE RETRY — your previous output failed validation with the following error(s):
${corrective}
Re-emit the FULL JSON object with ALL entries. Do not omit anything.`;
  }
  return base;
}

function geminiResponseSchema(): Record<string, unknown> {
  return {
    type: "OBJECT",
    properties: {
      directive_interpretation: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: {
            note_index: { type: "INTEGER" },
            applies: { type: "BOOLEAN" },
            directive_type: {
              type: "STRING",
              enum: [
                "solar_reduction",
                "minimum_battery_reserve",
                "no_charge_window",
                "no_discharge_window",
                "max_grid_window",
                "no_op",
              ],
            },
            structured_adjustment: {
              type: "OBJECT",
              nullable: true,
              properties: {
                hours: {
                  type: "ARRAY",
                  items: { type: "INTEGER" },
                },
                factor: { type: "NUMBER" },
                minimum_energy_kwh: { type: "NUMBER" },
                max_grid_kwh: { type: "NUMBER" },
              },
            },
            explanation: { type: "STRING" },
          },
          required: [
            "note_index",
            "applies",
            "directive_type",
            "structured_adjustment",
            "explanation",
          ],
        },
      },
    },
    required: ["directive_interpretation"],
  };
}

async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function callGemini(
  apiKey: string,
  model: string,
  userMessage: string
): Promise<LLMCallResult> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(
    apiKey
  )}`;

  const body = {
    systemInstruction: {
      role: "system",
      parts: [{ text: SYSTEM_PROMPT }],
    },
    contents: [
      {
        role: "user",
        parts: [{ text: userMessage }],
      },
    ],
    generationConfig: {
      temperature: 0,
      responseMimeType: "application/json",
      responseSchema: geminiResponseSchema(),
    },
  };

  const res = await fetchWithTimeout(
    url,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
    REQUEST_TIMEOUT_MS
  );

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`gemini_http_${res.status}:${text.slice(0, 200)}`);
  }

  const json = (await res.json()) as {
    candidates?: Array<{
      content?: { parts?: Array<{ text?: string }> };
    }>;
  };

  const text =
    json.candidates?.[0]?.content?.parts?.map((p) => p.text ?? "").join("") ??
    "";
  if (!text) {
    throw new Error("gemini_empty_response");
  }
  return { rawText: text, provider: `gemini:${model}` };
}

async function callOpenAI(
  apiKey: string,
  userMessage: string
): Promise<LLMCallResult> {
  const url = "https://api.openai.com/v1/chat/completions";
  const body = {
    model: OPENAI_MODEL,
    temperature: 0,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: userMessage },
    ],
  };

  const res = await fetchWithTimeout(
    url,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
    },
    REQUEST_TIMEOUT_MS
  );

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`openai_http_${res.status}:${text.slice(0, 200)}`);
  }

  const json = (await res.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const text = json.choices?.[0]?.message?.content ?? "";
  if (!text) {
    throw new Error("openai_empty_response");
  }
  return { rawText: text, provider: "openai:gpt-4o-mini" };
}

async function callLLMWithFallback(
  env: Env,
  req: OptimizeRequest,
  ctx: PromptContext,
  corrective?: string
): Promise<LLMCallResult> {
  const userMessage = buildUserMessage(req, ctx, corrective);
  const errors: string[] = [];

  const geminiKeys: Array<{ name: string; key: string | undefined }> = [
    { name: "GEMINI_API_KEY_1", key: env.GEMINI_API_KEY_1 },
    { name: "GEMINI_API_KEY_2", key: env.GEMINI_API_KEY_2 },
  ];

  for (const { name, key } of geminiKeys) {
    if (!key) continue;
    try {
      return await callGemini(key, GEMINI_MODEL_PRIMARY, userMessage);
    } catch (e) {
      errors.push(`${name}/${GEMINI_MODEL_PRIMARY}: ${(e as Error).message}`);
      if (
        (e as Error).message.startsWith("gemini_http_404") ||
        (e as Error).message.includes("404")
      ) {
        try {
          return await callGemini(key, GEMINI_MODEL_FALLBACK, userMessage);
        } catch (e2) {
          errors.push(
            `${name}/${GEMINI_MODEL_FALLBACK}: ${(e2 as Error).message}`
          );
        }
      }
    }
  }

  if (env.OPENAI_API_KEY) {
    try {
      return await callOpenAI(env.OPENAI_API_KEY, userMessage);
    } catch (e) {
      errors.push(`OPENAI/${OPENAI_MODEL}: ${(e as Error).message}`);
    }
  } else {
    errors.push("OPENAI_API_KEY: not configured");
  }

  throw new ApiError(
    500,
    "llm_unavailable",
    `All LLM providers failed: ${errors.join(" | ")}`
  );
}

function buildRetryMessage(result: GuardrailResult): string {
  return result.errors.map((err) => `- ${err}`).join("\n");
}

export interface InterpreterResult {
  entries: DirectiveEntry[];
  provider: string;
  attempts: number;
}

export async function interpretNotes(
  env: Env,
  req: OptimizeRequest
): Promise<InterpreterResult> {
  const ctx = computePromptContext(req);
  const guardrailCtx: GuardrailContext = {
    notes_count: req.operator_notes.length,
  };

  let lastValidationResult: GuardrailResult | null = null;
  let lastProvider = "unknown";

  for (let attempt = 1; attempt <= 2; attempt++) {
    const corrective =
      attempt === 2 && lastValidationResult
        ? buildRetryMessage(lastValidationResult)
        : undefined;

    let callResult: LLMCallResult;
    try {
      callResult = await callLLMWithFallback(env, req, ctx, corrective);
    } catch (e) {
      if (e instanceof ApiError) throw e;
      throw new ApiError(500, "llm_unavailable", "All LLM providers failed.");
    }
    lastProvider = callResult.provider;

    let parsed: LLMDirectiveResponse;
    try {
      parsed = parseLLMJson(callResult.rawText);
    } catch (e) {
      lastValidationResult = {
        ok: false,
        errors: [`JSON parse/shape error: ${(e as Error).message}`],
      };
      continue;
    }

    const validation = validateDirectiveOutput(parsed, guardrailCtx);
    if (validation.ok) {
      const entries: DirectiveEntry[] = parsed.directive_interpretation.map(
        (entry, idx) => ({
          ...entry,
          note_index: idx,
        })
      );
      return { entries, provider: lastProvider, attempts: attempt };
    }
    lastValidationResult = validation;
  }

  const errText =
    lastValidationResult?.errors.join(" | ") ?? "guardrail_validation_failed";
  throw new ApiError(
    422,
    "guardrail_failure",
    `Directive interpretation failed validation after retry: ${errText}`
  );
}
'@
Write-Utf8NoBom -Path (Join-Path $SrcDir "llmInterpreter.ts") -Content $llmInterpreterTs

Write-Host ""
Write-Host "Part 2a written. Run scaffold-part3.ps1 for optimizer/finalValidator/responseBuilder/index and root config files." -ForegroundColor Cyan