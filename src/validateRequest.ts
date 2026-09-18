// ============================================================================
// src/validateRequest.ts â€” Structural request validator.
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