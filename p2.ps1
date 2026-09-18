# ============================================================================
# scaffold-part3.ps1 — Writes optimizer.ts, finalValidator.ts,
# responseBuilder.ts, index.ts, and all root config files.
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
# src/optimizer.ts
# ============================================================================
$optimizerTs = @'
// ============================================================================
// src/optimizer.ts — Deterministic energy optimizer.
// ============================================================================

import {
  ApiError,
  BatterySpec,
  DirectiveEntry,
  HourlySolution,
  InternalHour,
  OptimizeRequest,
} from "./types";

const EPS = 0.01;
const MAX_OPT_ITERATIONS = 500;

function round2(x: number): number {
  return Math.round(x * 100) / 100;
}

interface InternalHourWithDirectives extends InternalHour {}

function buildInternalHours(
  req: OptimizeRequest & { directives: DirectiveEntry[] }
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

  for (const entry of req.directives) {
    if (!entry.applies || entry.directive_type === "no_op") continue;
    const adj = entry.structured_adjustment as Record<string, unknown> | null;
    if (!adj) continue;
    const hrs = adj.hours as number[] | undefined;
    if (!Array.isArray(hrs)) continue;

    switch (entry.directive_type) {
      case "solar_reduction": {
        const factor = adj.factor as number;
        for (const h of hrs) {
          if (h >= 0 && h < 24) internal[h].effective_solar *= factor;
        }
        break;
      }
      case "minimum_battery_reserve": {
        const minE = adj.minimum_energy_kwh as number;
        for (const h of hrs) {
          if (h >= 0 && h < 24) {
            internal[h].directive_min = Math.max(
              internal[h].directive_min,
              minE
            );
          }
        }
        break;
      }
      case "no_charge_window":
        for (const h of hrs) if (h >= 0 && h < 24) internal[h].no_charge = true;
        break;
      case "no_discharge_window":
        for (const h of hrs)
          if (h >= 0 && h < 24) internal[h].no_discharge = true;
        break;
      case "max_grid_window": {
        const cap = adj.max_grid_kwh as number;
        for (const h of hrs) {
          if (h >= 0 && h < 24) {
            internal[h].grid_cap = Math.min(internal[h].grid_cap, cap);
          }
        }
        break;
      }
      default:
        break;
    }
  }

  return internal;
}

interface BackwardPassResult {
  floor: number[];
  req_dis: number[];
  min_before: number[];
  effective_min_energy: number[];
}

function backwardPass(
  internal: InternalHour[],
  battery: BatterySpec
): BackwardPassResult {
  const base_min = battery.minimum_energy_kwh;
  const capacity = battery.capacity_kwh;
  const max_charge = battery.max_charge_kwh_per_hour;
  const max_discharge = battery.max_discharge_kwh_per_hour;

  const floor = new Array<number>(24).fill(0);
  const req_dis = new Array<number>(24).fill(0);

  for (let h = 0; h < 24; h++) {
    floor[h] = Math.max(
      base_min,
      internal[h].directive_min > 0 ? internal[h].directive_min : 0
    );
  }

  for (let h = 0; h < 24; h++) {
    const cap = internal[h].grid_cap;
    if (!Number.isFinite(cap)) {
      req_dis[h] = 0;
      continue;
    }
    const net = internal[h].demand - internal[h].effective_solar;
    req_dis[h] = Math.max(0, net - cap);
  }

  for (let h = 0; h < 24; h++) {
    if (req_dis[h] > max_discharge + EPS) {
      throw new ApiError(
        500,
        "infeasible",
        `infeasible_discharge_rate@${h}: required discharge ${req_dis[
          h
        ].toFixed(4)} > max ${max_discharge}`
      );
    }
  }

  const min_before = new Array<number>(25).fill(0);
  min_before[24] = 0;
  for (let h = 23; h >= 0; h--) {
    const own_need = floor[h] + req_dis[h];
    const charge_capacity = internal[h].no_charge ? 0 : max_charge;
    min_before[h] = Math.max(own_need, min_before[h + 1] - charge_capacity);
  }

  if (battery.initial_energy_kwh < min_before[0] - EPS) {
    throw new ApiError(
      500,
      "infeasible",
      `infeasible_initial_energy: initial=${battery.initial_energy_kwh}, required>=${min_before[0].toFixed(
        4
      )}`
    );
  }

  const effective_min_energy = new Array<number>(24).fill(0);
  for (let h = 0; h < 24; h++) {
    const charge_capacity = internal[h].no_charge ? 0 : max_charge;
    let em = Math.max(floor[h], min_before[h + 1] - charge_capacity);
    em = Math.min(em, capacity);
    effective_min_energy[h] = em;
  }

  return { floor, req_dis, min_before, effective_min_energy };
}

interface State {
  grid: number[];
  solar_used: number[];
  charge: number[];
  discharge: number[];
  E_after: number[];
}

function simulateForward(
  internal: InternalHour[],
  battery: BatterySpec,
  effective_min_energy: number[],
  override?: Partial<{ charge: number[]; discharge: number[] }>
): State {
  const capacity = battery.capacity_kwh;
  const grid = new Array<number>(24).fill(0);
  const solar_used = new Array<number>(24).fill(0);
  const charge = override?.charge
    ? [...override.charge]
    : new Array<number>(24).fill(0);
  const discharge = override?.discharge
    ? [...override.discharge]
    : new Array<number>(24).fill(0);
  const E_after = new Array<number>(24).fill(0);

  let E = battery.initial_energy_kwh;

  for (let h = 0; h < 24; h++) {
    const net = internal[h].demand - internal[h].effective_solar;
    const ch = charge[h];
    const dis = discharge[h];

    if (net >= 0) {
      solar_used[h] = internal[h].effective_solar;
      const remaining = net - dis;
      grid[h] = remaining - ch;
      if (grid[h] < 0) grid[h] = 0;
    } else {
      const surplus = -net;
      solar_used[h] = internal[h].demand + ch;
      if (solar_used[h] > internal[h].effective_solar) {
        solar_used[h] = internal[h].effective_solar;
      }
      grid[h] = 0;
      if (ch > surplus) grid[h] = ch - surplus;
    }

    E = E + ch - dis;
    E_after[h] = E;
  }

  return { grid, solar_used, charge, discharge, E_after };
}

function greedyForward(
  internal: InternalHour[],
  battery: BatterySpec,
  effective_min_energy: number[]
): State {
  const capacity = battery.capacity_kwh;
  const max_charge = battery.max_charge_kwh_per_hour;
  const max_discharge = battery.max_discharge_kwh_per_hour;

  const grid = new Array<number>(24).fill(0);
  const solar_used = new Array<number>(24).fill(0);
  const charge = new Array<number>(24).fill(0);
  const discharge = new Array<number>(24).fill(0);
  const E_after = new Array<number>(24).fill(0);

  let E = battery.initial_energy_kwh;

  for (let h = 0; h < 24; h++) {
    const net = internal[h].demand - internal[h].effective_solar;

    if (net >= 0) {
      solar_used[h] = internal[h].effective_solar;
      const remaining = net;
      let dis = 0;

      if (
        !internal[h].no_discharge &&
        E - max_discharge >= effective_min_energy[h] - EPS
      ) {
        dis = Math.min(
          max_discharge,
          remaining,
          Math.max(0, E - effective_min_energy[h])
        );
      }

      let g = remaining - dis;

      const cap = internal[h].grid_cap;
      if (Number.isFinite(cap) && g > cap + EPS) {
        const extra = Math.min(
          g - cap,
          max_discharge - dis,
          Math.max(0, E - dis - effective_min_energy[h])
        );
        if (extra > 0) {
          dis += extra;
          g -= extra;
        }
      }
      if (Number.isFinite(cap) && g > cap + EPS) {
        throw new ApiError(
          500,
          "infeasible",
          `infeasible_grid_cap@${h}: grid=${g.toFixed(4)} > cap=${cap}`
        );
      }

      discharge[h] = dis;
      grid[h] = g;
      charge[h] = 0;
    } else {
      const surplus = -net;
      let ch = 0;
      if (!internal[h].no_charge) {
        ch = Math.min(max_charge, surplus, capacity - E);
        if (ch < 0) ch = 0;
      }
      charge[h] = ch;
      solar_used[h] = internal[h].demand + ch;
      grid[h] = 0;
      discharge[h] = 0;
    }

    if (grid[h] < 0) grid[h] = 0;

    E = E + charge[h] - discharge[h];
    E_after[h] = E;

    if (E < effective_min_energy[h] - EPS) {
      throw new ApiError(
        500,
        "infeasible",
        `invariant_violation@${h}: E_after=${E.toFixed(4)} < eff_min=${effective_min_energy[
          h
        ].toFixed(4)}`
      );
    }
    if (E > capacity + EPS) {
      throw new ApiError(
        500,
        "infeasible",
        `invariant_violation@${h}: E_after=${E.toFixed(4)} > capacity=${capacity}`
      );
    }
  }

  return { grid, solar_used, charge, discharge, E_after };
}

function checkInvariants(
  internal: InternalHour[],
  battery: BatterySpec,
  effective_min_energy: number[],
  state: State,
  requireNeutral: boolean
): { ok: boolean; errors: string[] } {
  const errors: string[] = [];
  const capacity = battery.capacity_kwh;
  const max_charge = battery.max_charge_kwh_per_hour;
  const max_discharge = battery.max_discharge_kwh_per_hour;

  let E = battery.initial_energy_kwh;

  for (let h = 0; h < 24; h++) {
    const ch = state.charge[h];
    const dis = state.discharge[h];

    if (ch < -EPS) errors.push(`h${h}: charge<0 (${ch})`);
    if (dis < -EPS) errors.push(`h${h}: discharge<0 (${dis})`);
    if (ch > max_charge + EPS)
      errors.push(`h${h}: charge ${ch} > max_charge ${max_charge}`);
    if (dis > max_discharge + EPS)
      errors.push(`h${h}: discharge ${dis} > max_discharge ${max_discharge}`);

    if (internal[h].no_charge && ch > EPS)
      errors.push(`h${h}: charge ${ch} in no_charge window`);
    if (internal[h].no_discharge && dis > EPS)
      errors.push(`h${h}: discharge ${dis} in no_discharge window`);

    const bal =
      state.grid[h] + state.solar_used[h] + dis - internal[h].demand - ch;
    if (Math.abs(bal) > EPS)
      errors.push(`h${h}: energy balance off by ${bal.toFixed(6)}`);

    if (state.solar_used[h] > internal[h].effective_solar[h] + EPS)
      errors.push(
        `h${h}: solar_used ${state.solar_used[h]} > effective_solar ${internal[h].effective_solar[h]}`
      );

    if (
      Number.isFinite(internal[h].grid_cap) &&
      state.grid[h] > internal[h].grid_cap + EPS
    )
      errors.push(
        `h${h}: grid ${state.grid[h]} > grid_cap ${internal[h].grid_cap}`
      );

    if (state.grid[h] < -EPS) errors.push(`h${h}: grid<0 (${state.grid[h]})`);

    E = E + ch - dis;
    if (E < effective_min_energy[h] - EPS)
      errors.push(
        `h${h}: E_after ${E.toFixed(4)} < effective_min_energy ${effective_min_energy[
          h
        ].toFixed(4)}`
      );
    if (E > capacity + EPS)
      errors.push(`h${h}: E_after ${E.toFixed(4)} > capacity ${capacity}`);

    if (Math.abs(E - state.E_after[h]) > EPS)
      errors.push(
        `h${h}: E_after mismatch stored=${state.E_after[h]} computed=${E}`
      );
  }

  if (requireNeutral && Math.abs(E - battery.initial_energy_kwh) > EPS) {
    errors.push(
      `final E ${E.toFixed(4)} != initial ${battery.initial_energy_kwh} (delta ${(E - battery.initial_energy_kwh).toFixed(4)})`
    );
  }

  return { ok: errors.length === 0, errors };
}

function applyNeutrality(
  internal: InternalHour[],
  battery: BatterySpec,
  effective_min_energy: number[],
  initial: State
): State {
  let state: State = {
    grid: [...initial.grid],
    solar_used: [...initial.solar_used],
    charge: [...initial.charge],
    discharge: [...initial.discharge],
    E_after: [...initial.E_after],
  };

  let E_final = state.E_after[23];
  let delta = E_final - battery.initial_energy_kwh;

  if (Math.abs(delta) <= EPS) return state;

  const capacity = battery.capacity_kwh;
  const max_charge = battery.max_charge_kwh_per_hour;
  const max_discharge = battery.max_discharge_kwh_per_hour;

  let safety = 0;
  const MAX_NEUTRALITY_STEPS = 100000;

  while (Math.abs(delta) > EPS && safety < MAX_NEUTRALITY_STEPS) {
    safety++;
    if (delta > 0) {
      interface Cand {
        hour: number;
        kind: "A" | "B";
        savings: number;
      }
      const cands: Cand[] = [];
      for (let h = 0; h < 24; h++) {
        if (state.charge[h] > EPS && !internal[h].no_charge) {
          const isDeficit = internal[h].demand >= internal[h].effective_solar;
          cands.push({
            hour: h,
            kind: "A",
            savings: isDeficit ? internal[h].tariff : 0,
          });
        }
        if (
          !internal[h].no_discharge &&
          state.discharge[h] + 1 <= max_discharge + EPS
        ) {
          cands.push({
            hour: h,
            kind: "B",
            savings: internal[h].tariff,
          });
        }
      }
      cands.sort((a, b) => b.savings - a.savings);

      let applied = false;
      const tried = new Set<string>();
      for (const c of cands) {
        const key = `${c.kind}:${c.hour}`;
        if (tried.has(key)) continue;
        tried.add(key);

        const trialCharge = [...state.charge];
        const trialDischarge = [...state.discharge];

        if (c.kind === "A") {
          if (trialCharge[c.hour] < 1 - EPS) continue;
          trialCharge[c.hour] -= 1;
        } else {
          if (trialDischarge[c.hour] + 1 > max_discharge + EPS) continue;
          trialDischarge[c.hour] += 1;
        }

        const trialState = simulateForward(
          internal,
          battery,
          effective_min_energy,
          { charge: trialCharge, discharge: trialDischarge }
        );

        const check = checkInvariants(
          internal,
          battery,
          effective_min_energy,
          trialState,
          false
        );
        if (!check.ok) continue;

        state = trialState;
        E_final = state.E_after[23];
        delta = E_final - battery.initial_energy_kwh;
        applied = true;
        break;
      }
      if (!applied) {
        throw new ApiError(
          500,
          "infeasible",
          `neutrality_failed_positive_delta: delta=${delta.toFixed(4)}`
        );
      }
    } else {
      interface Cand {
        hour: number;
        kind: "A" | "B";
        cost: number;
      }
      const cands: Cand[] = [];
      for (let h = 0; h < 24; h++) {
        if (!internal[h].no_charge && state.charge[h] + 1 <= max_charge + EPS) {
          const isDeficit = internal[h].demand >= internal[h].effective_solar;
          if (isDeficit) {
            if (
              !Number.isFinite(internal[h].grid_cap) ||
              state.grid[h] + 1 <= internal[h].grid_cap + EPS
            ) {
              cands.push({ hour: h, kind: "A", cost: internal[h].tariff });
            }
          } else {
            const curtailment =
              internal[h].effective_solar - state.solar_used[h];
            if (curtailment >= 1 - EPS) {
              cands.push({ hour: h, kind: "A", cost: 0 });
            }
          }
        }
        if (state.discharge[h] > EPS) {
          if (
            !Number.isFinite(internal[h].grid_cap) ||
            state.grid[h] + 1 <= internal[h].grid_cap + EPS
          ) {
            cands.push({ hour: h, kind: "B", cost: internal[h].tariff });
          }
        }
      }
      cands.sort((a, b) => a.cost - b.cost);

      let applied = false;
      const tried = new Set<string>();
      for (const c of cands) {
        const key = `${c.kind}:${c.hour}`;
        if (tried.has(key)) continue;
        tried.add(key);

        const trialCharge = [...state.charge];
        const trialDischarge = [...state.discharge];

        if (c.kind === "A") {
          trialCharge[c.hour] += 1;
        } else {
          if (trialDischarge[c.hour] < 1 - EPS) continue;
          trialDischarge[c.hour] -= 1;
        }

        const trialState = simulateForward(
          internal,
          battery,
          effective_min_energy,
          { charge: trialCharge, discharge: trialDischarge }
        );

        const check = checkInvariants(
          internal,
          battery,
          effective_min_energy,
          trialState,
          false
        );
        if (!check.ok) continue;

        state = trialState;
        E_final = state.E_after[23];
        delta = E_final - battery.initial_energy_kwh;
        applied = true;
        break;
      }
      if (!applied) {
        throw new ApiError(
          500,
          "infeasible",
          `neutrality_failed_negative_delta: delta=${delta.toFixed(4)}`
        );
      }
    }
  }

  if (Math.abs(delta) > EPS) {
    throw new ApiError(
      500,
      "infeasible",
      `neutrality_did_not_converge: delta=${delta.toFixed(4)}`
    );
  }

  return state;
}

function computeCost(internal: InternalHour[], state: State): number {
  let cost = 0;
  for (let h = 0; h < 24; h++) cost += state.grid[h] * internal[h].tariff;
  return cost;
}

function localImprovement(
  internal: InternalHour[],
  battery: BatterySpec,
  effective_min_energy: number[],
  initial: State
): State {
  let state = initial;
  let cost = computeCost(internal, state);

  const max_charge = battery.max_charge_kwh_per_hour;
  const max_discharge = battery.max_discharge_kwh_per_hour;
  const capacity = battery.capacity_kwh;

  let iter = 0;
  let improved = true;

  while (improved && iter < MAX_OPT_ITERATIONS) {
    iter++;
    improved = false;

    outerA: for (let a = 0; a < 24; a++) {
      if (state.charge[a] < 1 - EPS) continue;
      if (internal[a].no_charge) continue;
      const isDeficitA = internal[a].demand >= internal[a].effective_solar;
      if (!isDeficitA) continue;

      for (let b = a + 1; b < 24; b++) {
        if (internal[a].tariff <= internal[b].tariff + EPS) continue;
        if (internal[b].no_charge) continue;
        if (state.charge[b] + 1 > max_charge + EPS) continue;

        const E_before_b =
          b === 0 ? battery.initial_energy_kwh : state.E_after[b - 1];
        if (E_before_b - 1 + state.charge[b] + 1 > capacity + EPS) continue;
        if (E_before_b - 1 < effective_min_energy[b] - EPS) continue;

        const trialCharge = [...state.charge];
        trialCharge[a] -= 1;
        trialCharge[b] += 1;

        const trial = simulateForward(
          internal,
          battery,
          effective_min_energy,
          { charge: trialCharge, discharge: state.discharge }
        );
        const check = checkInvariants(
          internal,
          battery,
          effective_min_energy,
          trial,
          false
        );
        if (!check.ok) continue;
        if (Math.abs(trial.E_after[23] - battery.initial_energy_kwh) > EPS)
          continue;

        const newCost = computeCost(internal, trial);
        if (newCost < cost - EPS) {
          state = trial;
          cost = newCost;
          improved = true;
          break outerA;
        }
      }
    }
    if (improved) continue;

    outerB: for (let a = 0; a < 24; a++) {
      if (state.discharge[a] < 1 - EPS) continue;
      if (internal[a].no_discharge) continue;

      for (let b = a + 1; b < 24; b++) {
        if (internal[a].tariff >= internal[b].tariff - EPS) continue;
        if (internal[b].no_discharge) continue;
        if (state.discharge[b] + 1 > max_discharge + EPS) continue;

        const trialDischarge = [...state.discharge];
        trialDischarge[a] -= 1;
        trialDischarge[b] += 1;

        const trial = simulateForward(
          internal,
          battery,
          effective_min_energy,
          { charge: state.charge, discharge: trialDischarge }
        );
        const check = checkInvariants(
          internal,
          battery,
          effective_min_energy,
          trial,
          false
        );
        if (!check.ok) continue;
        if (Math.abs(trial.E_after[23] - battery.initial_energy_kwh) > EPS)
          continue;

        const newCost = computeCost(internal, trial);
        if (newCost < cost - EPS) {
          state = trial;
          cost = newCost;
          improved = true;
          break outerB;
        }
      }
    }
  }

  return state;
}

export function optimize(
  req: OptimizeRequest,
  directives: DirectiveEntry[]
): HourlySolution[] {
  const reqWithDirectives = {
    ...req,
    directives,
  };

  const internal = buildInternalHours(reqWithDirectives);

  const backward = backwardPass(internal, req.battery);

  const greedy = greedyForward(
    internal,
    req.battery,
    backward.effective_min_energy
  );

  const neutral = applyNeutrality(
    internal,
    req.battery,
    backward.effective_min_energy,
    greedy
  );

  const improved = localImprovement(
    internal,
    req.battery,
    backward.effective_min_energy,
    neutral
  );

  const finalCheck = checkInvariants(
    internal,
    req.battery,
    backward.effective_min_energy,
    improved,
    true
  );
  if (!finalCheck.ok) {
    throw new ApiError(
      500,
      "infeasible",
      `optimizer_final_invariant_failure: ${finalCheck.errors
        .slice(0, 5)
        .join(" | ")}`
    );
  }

  const solutions: HourlySolution[] = [];
  for (let h = 0; h < 24; h++) {
    const ch = improved.charge[h];
    const dis = improved.discharge[h];

    let action: "charge" | "discharge" | "idle" = "idle";
    let battKwh = 0;
    if (ch > EPS) {
      action = "charge";
      battKwh = ch;
    } else if (dis > EPS) {
      action = "discharge";
      battKwh = dis;
    }

    solutions.push({
      hour: h,
      grid: improved.grid[h],
      solar_used: improved.solar_used[h],
      charge: ch,
      discharge: dis,
      battery_action: action,
      battery_kwh: battKwh,
      battery_energy_after: improved.E_after[h],
    });
  }

  return solutions;
}

export { round2 };
'@
Write-Utf8NoBom -Path (Join-Path $SrcDir "optimizer.ts") -Content $optimizerTs

# ============================================================================
# src/finalValidator.ts
# ============================================================================
$finalValidatorTs = @'
// ============================================================================
// src/finalValidator.ts — Replay validation with EPSILON checks and
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
'@
Write-Utf8NoBom -Path (Join-Path $SrcDir "finalValidator.ts") -Content $finalValidatorTs

# ============================================================================
# src/responseBuilder.ts
# ============================================================================
$responseBuilderTs = @'
// ============================================================================
// src/responseBuilder.ts — Assemble the final OptimizeResponse JSON.
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
'@
Write-Utf8NoBom -Path (Join-Path $SrcDir "responseBuilder.ts") -Content $responseBuilderTs

# ============================================================================
# src/index.ts
# ============================================================================
$indexTs = @'
// ============================================================================
// src/index.ts — Cloudflare Worker entry point.
// ============================================================================

import { ApiError, Env, OptimizeResponse } from "./types";
import { validateRequest } from "./validateRequest";
import { interpretNotes } from "./llmInterpreter";
import { optimize } from "./optimizer";
import { replayValidate } from "./finalValidator";
import { buildResponse } from "./responseBuilder";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Max-Age": "86400",
};

function jsonResponse(
  body: unknown,
  status: number,
  extraHeaders?: Record<string, string>
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
      ...(extraHeaders ?? {}),
    },
  });
}

function errorResponse(
  status: number,
  code: string,
  message?: string
): Response {
  const body: { error: string; message?: string } = { error: code };
  if (message && status !== 500) {
    body.message = message;
  }
  return jsonResponse(body, status);
}

async function handleHealth(): Promise<Response> {
  return jsonResponse({ status: "ok" }, 200);
}

async function handleOptimize(request: Request, env: Env): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return errorResponse(400, "invalid_json", "Request body must be valid JSON.");
  }

  let parsedReq;
  try {
    parsedReq = validateRequest(body);
  } catch (e) {
    if (e instanceof ApiError) {
      return errorResponse(e.status, e.code, e.message);
    }
    return errorResponse(400, "invalid_request", "Structural validation failed.");
  }

  let interpreterResult;
  try {
    interpreterResult = await interpretNotes(env, parsedReq);
  } catch (e) {
    if (e instanceof ApiError) {
      if (e.status === 500) return errorResponse(500, e.code);
      return errorResponse(e.status, e.code, e.message);
    }
    return errorResponse(500, "llm_unavailable");
  }

  let plan;
  try {
    plan = optimize(parsedReq, interpreterResult.entries);
  } catch (e) {
    if (e instanceof ApiError) return errorResponse(500, e.code);
    return errorResponse(500, "optimizer_failure");
  }

  let totals;
  try {
    totals = replayValidate(parsedReq, interpreterResult.entries, plan);
  } catch (e) {
    if (e instanceof ApiError) return errorResponse(500, e.code);
    return errorResponse(500, "validation_failure");
  }

  let response: OptimizeResponse;
  try {
    response = buildResponse({
      scenario_id: parsedReq.scenario_id,
      directives: interpreterResult.entries,
      plan,
      total_grid_kwh: totals.total_grid_kwh,
      total_cost_bdt: totals.total_cost_bdt,
      peak_grid_kwh: totals.peak_grid_kwh,
    });
  } catch {
    return errorResponse(500, "response_build_failure");
  }

  return jsonResponse(response, 200);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const method = request.method.toUpperCase();
    const path = url.pathname;

    if (method === "OPTIONS") {
      return new Response(null, { status: 204, headers: { ...CORS_HEADERS } });
    }

    try {
      if (method === "GET" && (path === "/health" || path === "/health/")) {
        return await handleHealth();
      }

      if (
        method === "POST" &&
        (path === "/optimize-energy" || path === "/optimize-energy/")
      ) {
        return await handleOptimize(request, env);
      }

      return errorResponse(404, "not_found", `No route for ${method} ${path}`);
    } catch {
      return errorResponse(500, "internal_error");
    }
  },
};
'@
Write-Utf8NoBom -Path (Join-Path $SrcDir "index.ts") -Content $indexTs

# ============================================================================
# Root files: wrangler.jsonc, package.json, tsconfig.json, .gitignore, README.md
# ============================================================================
$wranglerJsonc = @'
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "smart-campus-energy-optimizer",
  "main": "src/index.ts",
  "compatibility_date": "2024-01-01",
  "compatibility_flags": ["nodejs_compat"],
  "observability": {
    "enabled": true
  },
  "vars": {
    "ENVIRONMENT": "production"
  }
}
'@
Write-Utf8NoBom -Path (Join-Path $ProjectRoot "wrangler.jsonc") -Content $wranglerJsonc

$packageJson = @'
{
  "name": "smart-campus-energy-optimizer",
  "version": "1.0.0",
  "private": true,
  "description": "Smart Campus Energy Optimization Challenge API - Cloudflare Worker",
  "main": "src/index.ts",
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "typecheck": "tsc --noEmit",
    "build": "wrangler deploy --dry-run --outdir=dist"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^4.20240117.0",
    "typescript": "^5.3.3",
    "wrangler": "^3.28.0"
  }
}
'@
Write-Utf8NoBom -Path (Join-Path $ProjectRoot "package.json") -Content $packageJson

$tsconfigJson = @'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "lib": ["ES2022"],
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "strictFunctionTypes": true,
    "strictBindCallApply": true,
    "strictPropertyInitialization": true,
    "noImplicitThis": true,
    "alwaysStrict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": false,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": false,
    "noEmit": true
  },
  "include": ["src/**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
'@
Write-Utf8NoBom -Path (Join-Path $ProjectRoot "tsconfig.json") -Content $tsconfigJson

$gitignore = @'
node_modules/
dist/
.wrangler/
.dev.vars
*.log
.DS_Store
'@
Write-Utf8NoBom -Path (Join-Path $ProjectRoot ".gitignore") -Content $gitignore

Write-Host ""
Write-Host "All files written successfully." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  npm install"
Write-Host "  wrangler secret put GEMINI_API_KEY_1"
Write-Host "  wrangler secret put GEMINI_API_KEY_2"
Write-Host "  wrangler secret put OPENAI_API_KEY"
Write-Host "  npm run dev"