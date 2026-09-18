// ============================================================================
// src/finalValidator.ts â€” Replay validation with EPSILON checks and
// recomputation of totals.
// ============================================================================

import {
  ApiError,
  BatterySpec,
  DirectiveEntry,
  HourlyPlanEntry,
  HourlySolution,
  InternalHour,
  OptimizeRequest,
} from "./types";

const EPS = 0.01;

export interface ReplayResult {
  total_grid_kwh: number;
  total_cost_bdt: number;
  peak_grid_kwh: number;
}

function rebuildInternalHours(
  req: OptimizeRequest,
  directives: DirectiveEntry[]
): InternalHour[] {
  const internal: InternalHour[] = req.hours.map((h) => ({
    hour: h.hour,
    demand: h.demand_kwh,
    effective_solar: h.solar_kwh,
    tariff: h.tariff_bdt_per_kwh,
    grid_cap: Number.POSITIVE_INFINITY,
    no_charge: false,
    no_discharge: false,
    directive_min: 0,
  }));

  for (const entry of directives) {
    if (!entry.applies || entry.directive_type === "no_op") continue;
    const adj = entry.structured_adjustment as Record<string, unknown> | null;
    if (!adj) continue;
    const hrs = adj.hours as number[] | undefined;
    if (!Array.isArray(hrs)) continue;

    switch (entry.directive_type) {
      case "solar_reduction": {
        const factor = adj.factor as number;
        for (const h of hrs) internal[h].effective_solar *= factor;
        break;
      }
      case "minimum_battery_reserve": {
        const minE = adj.minimum_energy_kwh as number;
        for (const h of hrs)
          internal[h].directive_min = Math.max(internal[h].directive_min, minE);
        break;
      }
      case "no_charge_window":
        for (const h of hrs) internal[h].no_charge = true;
        break;
      case "no_discharge_window":
        for (const h of hrs) internal[h].no_discharge = true;
        break;
      case "max_grid_window": {
        const cap = adj.max_grid_kwh as number;
        for (const h of hrs)
          internal[h].grid_cap = Math.min(internal[h].grid_cap, cap);
        break;
      }
      default:
        break;
    }
  }

  return internal;
}

export function replayValidate(
  req: OptimizeRequest,
  directives: DirectiveEntry[],
  plan: HourlySolution[]
): ReplayResult {
  if (plan.length !== 24) {
    throw new ApiError(500, "validation_failed", "plan must have 24 entries");
  }

  const internal = rebuildInternalHours(req, directives);
  const battery: BatterySpec = req.battery;

  let E = battery.initial_energy_kwh;
  let totalGrid = 0;
  let totalCost = 0;
  let peakGrid = 0;

  for (let h = 0; h < 24; h++) {
    const p = plan[h];
    if (p.hour !== h) {
      throw new ApiError(
        500,
        "validation_failed",
        `plan[${h}].hour=${p.hour}, expected ${h}`
      );
    }

    const ch = p.charge;
    const dis = p.discharge;

    if (Math.abs(p.battery_kwh - Math.max(ch, dis)) > EPS) {
      if (p.battery_action === "idle") {
        if (p.battery_kwh > EPS) {
          throw new ApiError(
            500,
            "validation_failed",
            `h${h}: idle but battery_kwh=${p.battery_kwh}`
          );
        }
      } else {
        throw new ApiError(
          500,
          "validation_failed",
          `h${h}: battery_kwh mismatch (${p.battery_kwh} vs max(${ch},${dis}))`
        );
      }
    }

    if (ch > EPS && dis > EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: simultaneous charge+discharge`
      );
    }

    if (ch > battery.max_charge_kwh_per_hour + EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: charge ${ch} > max_charge ${battery.max_charge_kwh_per_hour}`
      );
    }
    if (dis > battery.max_discharge_kwh_per_hour + EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: discharge ${dis} > max_discharge ${battery.max_discharge_kwh_per_hour}`
      );
    }

    if (internal[h].no_charge && ch > EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: charge in no_charge window`
      );
    }
    if (internal[h].no_discharge && dis > EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: discharge in no_discharge window`
      );
    }

    if (p.solar_used_kwh > internal[h].effective_solar + EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: solar_used ${p.solar_used_kwh} > effective_solar ${internal[h].effective_solar}`
      );
    }

    if (
      Number.isFinite(internal[h].grid_cap) &&
      p.grid_kwh > internal[h].grid_cap + EPS
    ) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: grid ${p.grid_kwh} > cap ${internal[h].grid_cap}`
      );
    }

    if (p.grid_kwh < -EPS || p.solar_used_kwh < -EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: negative grid/solar`
      );
    }

    const lhs = p.grid_kwh + p.solar_used_kwh + dis;
    const rhs = internal[h].demand + ch;
    if (Math.abs(lhs - rhs) > EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: energy balance off by ${(lhs - rhs).toFixed(6)}`
      );
    }

    E = E + ch - dis;
    if (E < battery.minimum_energy_kwh - EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: E_after ${E.toFixed(4)} < base minimum ${battery.minimum_energy_kwh}`
      );
    }
    if (internal[h].directive_min > 0 && E < internal[h].directive_min - EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: E_after ${E.toFixed(4)} < directive minimum ${internal[h].directive_min}`
      );
    }
    if (E > battery.capacity_kwh + EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: E_after ${E.toFixed(4)} > capacity ${battery.capacity_kwh}`
      );
    }
    if (Math.abs(E - p.battery_energy_after_kwh) > EPS) {
      throw new ApiError(
        500,
        "validation_failed",
        `h${h}: battery_energy_after mismatch stored=${p.battery_energy_after_kwh} computed=${E}`
      );
    }

    totalGrid += p.grid_kwh;
    totalCost += p.grid_kwh * internal[h].tariff;
    if (p.grid_kwh > peakGrid) peakGrid = p.grid_kwh;
  }

  if (Math.abs(E - battery.initial_energy_kwh) > EPS) {
    throw new ApiError(
      500,
      "validation_failed",
      `final E ${E.toFixed(4)} != initial ${battery.initial_energy_kwh}`
    );
  }

  return {
    total_grid_kwh: Math.round(totalGrid * 100) / 100,
    total_cost_bdt: Math.round(totalCost * 100) / 100,
    peak_grid_kwh: Math.round(peakGrid * 100) / 100,
  };
}

export function toHourlyPlan(plan: HourlySolution[]): HourlyPlanEntry[] {
  return plan.map((p) => ({
    hour: p.hour,
    grid_kwh: Math.round(p.grid * 100) / 100,
    solar_used_kwh: Math.round(p.solar_used * 100) / 100,
    battery_action: p.battery_action,
    battery_kwh: Math.round(p.battery_kwh * 100) / 100,
    battery_energy_after_kwh: Math.round(p.battery_energy_after * 100) / 100,
  }));
}