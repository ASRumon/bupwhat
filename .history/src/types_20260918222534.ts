// ============================================================================
// src/types.ts â€” All TypeScript interfaces for the Smart Campus Energy
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