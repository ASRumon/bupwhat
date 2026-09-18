# ============================================================================
# scaffold.ps1 — Create the src/ folder and all TypeScript source files
# for the Smart Campus Energy Optimization Cloudflare Worker.
#
# Usage:
#   cd <project-root>
#   powershell -ExecutionPolicy Bypass -File .\scaffold.ps1
# ============================================================================

$ErrorActionPreference = "Stop"

# --- Resolve project root (folder containing this script) -------------------
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
$SrcDir = Join-Path $ProjectRoot "src"

Write-Host "Project root: $ProjectRoot" -ForegroundColor Cyan
Write-Host "Creating src at: $SrcDir" -ForegroundColor Cyan

if (-not (Test-Path $SrcDir)) {
    New-Item -ItemType Directory -Path $SrcDir | Out-Null
}

# --- Helper: write UTF-8 without BOM ----------------------------------------
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
# src/types.ts
# ============================================================================
$typesTs = @'
// ============================================================================
// src/types.ts — All TypeScript interfaces for the Smart Campus Energy
// Optimization Challenge API.
// ============================================================================

// ---------------------------------------------------------------------------
// Environment bindings
// ---------------------------------------------------------------------------
export interface Env {
  GEMINI_API_KEY_1?: string;
  GEMINI_API_KEY_2?: string;
  OPENAI_API_KEY?: string;
  ENVIRONMENT?: string;
}

// ---------------------------------------------------------------------------
// Request schema
// ---------------------------------------------------------------------------
export interface HourInput {
  hour: number;
  demand_kwh: number;
  solar_kwh: number;
  tariff_bdt_per_kwh: number;
}

export interface BatterySpec {
  capacity_kwh: number;
  initial_energy_kwh: number;
  minimum_energy_kwh: number;
  max_charge_kwh_per_hour: number;
  max_discharge_kwh_per_hour: number;
}

export interface OptimizeRequest {
  scenario_id: string;
  operator_notes: string[];
  hours: HourInput[];
  battery: BatterySpec;
}

// ---------------------------------------------------------------------------
// Directive types
// ---------------------------------------------------------------------------
export type DirectiveType =
  | "solar_reduction"
  | "minimum_battery_reserve"
  | "no_charge_window"
  | "no_discharge_window"
  | "max_grid_window"
  | "no_op";

export interface SolarReductionAdjustment {
  hours: number[];
  factor: number;
}

export interface MinimumBatteryReserveAdjustment {
  hours: number[];
  minimum_energy_kwh: number;
}

export interface NoChargeWindowAdjustment {
  hours: number[];
}

export interface NoDischargeWindowAdjustment {
  hours: number[];
}

export interface MaxGridWindowAdjustment {
  hours: number[];
  max_grid_kwh: number;
}

export type StructuredAdjustment =
  | SolarReductionAdjustment
  | MinimumBatteryReserveAdjustment
  | NoChargeWindowAdjustment
  | NoDischargeWindowAdjustment
  | MaxGridWindowAdjustment
  | null;

export interface DirectiveEntry {
  note_index: number;
  applies: boolean;
  directive_type: DirectiveType;
  structured_adjustment: StructuredAdjustment;
  explanation: string;
}

export interface LLMDirectiveResponse {
  directive_interpretation: DirectiveEntry[];
}

// ---------------------------------------------------------------------------
// Hourly plan / response schema
// ---------------------------------------------------------------------------
export type BatteryAction = "charge" | "discharge" | "idle";

export interface HourlyPlanEntry {
  hour: number;
  grid_kwh: number;
  solar_used_kwh: number;
  battery_action: BatteryAction;
  battery_kwh: number;
  battery_energy_after_kwh: number;
}

export interface OptimizeResponse {
  scenario_id: string;
  directive_interpretation: DirectiveEntry[];
  hourly_plan: HourlyPlanEntry[];
  total_grid_kwh: number;
  total_cost_bdt: number;
  peak_grid_kwh: number;
  plan_summary: string;
}

// ---------------------------------------------------------------------------
// Internal optimizer structures
// ---------------------------------------------------------------------------
export interface InternalHour {
  hour: number;
  demand: number;
  effective_solar: number;
  tariff: number;
  grid_cap: number;
  no_charge: boolean;
  no_discharge: boolean;
  directive_min: number;
}

export interface HourlySolution {
  hour: number;
  grid: number;
  solar_used: number;
  charge: number;
  discharge: number;
  battery_action: BatteryAction;
  battery_kwh: number;
  battery_energy_after: number;
}

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------
export class ApiError extends Error {
  public readonly status: number;
  public readonly code: string;

  constructor(status: number, code: string, message?: string) {
    super(message ?? code);
    this.status = status;
    this.code = code;
    this.name = "ApiError";
  }
}

// ---------------------------------------------------------------------------
// LLM call result (provider-agnostic)
// ---------------------------------------------------------------------------
export interface LLMCallResult {
  rawText: string;
  provider: string;
}
'@
Write-Utf8NoBom -Path (Join-Path $SrcDir "types.ts") -Content $typesTs

# ============================================================================
# src/validateRequest.ts
# ============================================================================
$validateRequestTs = @'
// ============================================================================
// src/validateRequest.ts — Structural request validator.
// Throws ApiError(400, ...) on any structural violation.
// ============================================================================

import {
  ApiError,
  BatterySpec,
  HourInput,
  OptimizeRequest,
} from "./types";

const MAX_NOTES = 3;
const MIN_NOTES = 1;
const REQUIRED_HOURS = 24;

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isFiniteNumber(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function isNonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v.trim().length > 0;
}

function badRequest(message: string): never {
  throw new ApiError(400, "invalid_request", message);
}

export function validateRequest(body: unknown): OptimizeRequest {
  if (!isPlainObject(body)) {
    badRequest("Request body must be a JSON object.");
  }

  if (!isNonEmptyString(body.scenario_id)) {
    badRequest("scenario_id must be a non-empty string.");
  }
  const scenarioId = body.scenario_id;

  if (!Array.isArray(body.operator_notes)) {
    badRequest("operator_notes must be an array of strings.");
  }
  const notesRaw = body.operator_notes as unknown[];
  if (notesRaw.length < MIN_NOTES || notesRaw.length > MAX_NOTES) {
    badRequest(
      `operator_notes must contain between ${MIN_NOTES} and ${MAX_NOTES} entries (received ${notesRaw.length}).`
    );
  }
  const operatorNotes: string[] = [];
  for (let i = 0; i < notesRaw.length; i++) {
    const n = notesRaw[i];
    if (typeof n !== "string") {
      badRequest(`operator_notes[${i}] must be a string.`);
    }
    if (n.trim().length === 0) {
      badRequest(`operator_notes[${i}] must be a non-empty string.`);
    }
    operatorNotes.push(n);
  }

  if (!Array.isArray(body.hours)) {
    badRequest("hours must be an array of 24 hourly entries.");
  }
  const hoursRaw = body.hours as unknown[];
  if (hoursRaw.length !== REQUIRED_HOURS) {
    badRequest(
      `hours must contain exactly ${REQUIRED_HOURS} entries (received ${hoursRaw.length}).`
    );
  }

  const seenHours = new Set<number>();
  const hours: HourInput[] = [];
  for (let i = 0; i < hoursRaw.length; i++) {
    const entry = hoursRaw[i];
    if (!isPlainObject(entry)) {
      badRequest(`hours[${i}] must be an object.`);
    }
    const h = entry.hour;
    const demand = entry.demand_kwh;
    const solar = entry.solar_kwh;
    const tariff = entry.tariff_bdt_per_kwh;

    if (!isFiniteNumber(h) || !Number.isInteger(h) || h < 0 || h > 23) {
      badRequest(`hours[${i}].hour must be an integer in 0..23.`);
    }
    if (seenHours.has(h)) {
      badRequest(`hours contains duplicate hour value: ${h}.`);
    }
    seenHours.add(h);

    if (!isFiniteNumber(demand) || demand < 0) {
      badRequest(`hours[${i}].demand_kwh must be a finite number >= 0.`);
    }
    if (!isFiniteNumber(solar) || solar < 0) {
      badRequest(`hours[${i}].solar_kwh must be a finite number >= 0.`);
    }
    if (!isFiniteNumber(tariff) || tariff < 0) {
      badRequest(`hours[${i}].tariff_bdt_per_kwh must be a finite number >= 0.`);
    }

    hours.push({
      hour: h,
      demand_kwh: demand,
      solar_kwh: solar,
      tariff_bdt_per_kwh: tariff,
    });
  }

  for (let h = 0; h < 24; h++) {
    if (!seenHours.has(h)) {
      badRequest(`hours is missing required hour ${h}.`);
    }
  }

  hours.sort((a, b) => a.hour - b.hour);

  if (!isPlainObject(body.battery)) {
    badRequest("battery must be an object.");
  }
  const b = body.battery;

  const capacity = b.capacity_kwh;
  const initial = b.initial_energy_kwh;
  const minimum = b.minimum_energy_kwh;
  const maxCharge = b.max_charge_kwh_per_hour;
  const maxDischarge = b.max_discharge_kwh_per_hour;

  if (!isFiniteNumber(capacity) || capacity <= 0) {
    badRequest("battery.capacity_kwh must be a finite number > 0.");
  }
  if (!isFiniteNumber(minimum) || minimum < 0) {
    badRequest("battery.minimum_energy_kwh must be a finite number >= 0.");
  }
  if (minimum > capacity) {
    badRequest("battery.minimum_energy_kwh must be <= battery.capacity_kwh.");
  }
  if (!isFiniteNumber(initial)) {
    badRequest("battery.initial_energy_kwh must be a finite number.");
  }
  if (initial > capacity) {
    badRequest("battery.initial_energy_kwh must be <= battery.capacity_kwh.");
  }
  if (initial < minimum) {
    badRequest("battery.initial_energy_kwh must be >= battery.minimum_energy_kwh.");
  }
  if (!isFiniteNumber(maxCharge) || maxCharge <= 0) {
    badRequest("battery.max_charge_kwh_per_hour must be a finite number > 0.");
  }
  if (!isFiniteNumber(maxDischarge) || maxDischarge <= 0) {
    badRequest("battery.max_discharge_kwh_per_hour must be a finite number > 0.");
  }

  const battery: BatterySpec = {
    capacity_kwh: capacity,
    initial_energy_kwh: initial,
    minimum_energy_kwh: minimum,
    max_charge_kwh_per_hour: maxCharge,
    max_discharge_kwh_per_hour: maxDischarge,
  };

  return {
    scenario_id: scenarioId,
    operator_notes: operatorNotes,
    hours,
    battery,
  };
}
'@
Write-Utf8NoBom -Path (Join-Path $SrcDir "validateRequest.ts") -Content $validateRequestTs

Write-Host ""
Write-Host "Base files written. Continuing with LLM, guardrail, optimizer, validator, and index..." -ForegroundColor Cyan
Write-Host "Run the companion script scaffold-part2.ps1 for the remaining files," -ForegroundColor Yellow
Write-Host "or continue below if you pasted the full script." -ForegroundColor Yellow