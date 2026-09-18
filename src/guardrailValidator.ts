// ============================================================================
// src/guardrailValidator.ts â€” Deterministic validator for LLM directive output.
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