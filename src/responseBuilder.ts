// ============================================================================
// src/responseBuilder.ts â€” Assemble the final OptimizeResponse JSON.
// ============================================================================

import {
  DirectiveEntry,
  HourlyPlanEntry,
  HourlySolution,
  OptimizeResponse,
} from "./types";
import { toHourlyPlan } from "./finalValidator";

interface SummaryInput {
  total_cost_bdt: number;
  total_grid_kwh: number;
  plan: HourlySolution[];
}

function buildSummary(input: SummaryInput): string {
  const parts: string[] = [];
  parts.push(
    `Total cost ${input.total_cost_bdt.toFixed(2)} BDT; total grid ${input.total_grid_kwh.toFixed(2)} kWh.`
  );

  const chargeHours = input.plan
    .filter((p) => p.battery_action === "charge")
    .map((p) => p.hour);
  const disHours = input.plan
    .filter((p) => p.battery_action === "discharge")
    .map((p) => p.hour);
  const gridHours = input.plan.filter((p) => p.grid > 0.01).map((p) => p.hour);

  if (chargeHours.length > 0) {
    parts.push(`Charged during hours ${compressRanges(chargeHours)}`);
  }
  if (disHours.length > 0) {
    parts.push(`discharged during ${compressRanges(disHours)}`);
  }
  if (gridHours.length > 0) {
    parts.push(`grid import at ${compressRanges(gridHours)}`);
  }

  let s = parts.join("; ") + ".";
  if (s.length > 500) s = s.slice(0, 497) + "...";
  return s;
}

function compressRanges(hours: number[]): string {
  if (hours.length === 0) return "";
  const sorted = [...hours].sort((a, b) => a - b);
  const ranges: string[] = [];
  let start = sorted[0];
  let prev = sorted[0];

  for (let i = 1; i < sorted.length; i++) {
    const h = sorted[i];
    if (h === prev + 1) {
      prev = h;
    } else {
      ranges.push(start === prev ? `${start}` : `${start}-${prev}`);
      start = h;
      prev = h;
    }
  }
  ranges.push(start === prev ? `${start}` : `${start}-${prev}`);
  return ranges.join(", ");
}

export interface BuildResponseInput {
  scenario_id: string;
  directives: DirectiveEntry[];
  plan: HourlySolution[];
  total_grid_kwh: number;
  total_cost_bdt: number;
  peak_grid_kwh: number;
}

export function buildResponse(input: BuildResponseInput): OptimizeResponse {
  const hourly: HourlyPlanEntry[] = toHourlyPlan(input.plan);

  const summary = buildSummary({
    total_cost_bdt: input.total_cost_bdt,
    total_grid_kwh: input.total_grid_kwh,
    plan: input.plan,
  });

  return {
    scenario_id: input.scenario_id,
    directive_interpretation: input.directives.map((d) => ({
      note_index: d.note_index,
      applies: d.applies,
      directive_type: d.directive_type,
      structured_adjustment: d.structured_adjustment,
      explanation:
        typeof d.explanation === "string" && d.explanation.length > 200
          ? d.explanation.slice(0, 200)
          : d.explanation,
    })),
    hourly_plan: hourly,
    total_grid_kwh: input.total_grid_kwh,
    total_cost_bdt: input.total_cost_bdt,
    peak_grid_kwh: input.peak_grid_kwh,
    plan_summary: summary,
  };
}