// ============================================================================
// src/llmInterpreter.ts â€” LLM directive interpreter.
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

CORRECTIVE RETRY â€” your previous output failed validation with the following error(s):
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