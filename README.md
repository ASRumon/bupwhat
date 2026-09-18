\# GridWise — Smart Campus Energy Optimizer

> **BUP CSE Fest 2026 Hackathon · Preliminary Round Submission**
> LLM-assisted operator directive interpretation for 24-hour smart campus energy scheduling.

A Cloudflare Worker that accepts a 24-hour energy scenario plus 1–3 free-text operator notes, uses an LLM to interpret those notes into structured directives, validates them deterministically, then runs a deterministic optimizer to produce a valid, low-cost hourly schedule.

---

## Architecture

```
┌──────────────────┐   ┌────────────────┐   ┌─────────────────┐   ┌────────────────┐   ┌──────────────┐
│  POST body       │──▶│  validateRequest│──▶│  llmInterpreter │──▶│  guardrail     │──▶│  optimizer   │
│  (24h + notes)   │   │  (structural)   │   │  (Gemini/OpenAI)│   │  Validator     │   │  (deterministic)│
└──────────────────┘   └────────────────┘   └─────────────────┘   └────────────────┘   └──────────────┘
                                                                                              │
                                                                                              ▼
                                                                                    ┌──────────────────┐
                                                                                    │ finalValidator   │
                                                                                    │ (replay + totals)│
                                                                                    └──────────────────┘
                                                                                              │
                                                                                              ▼
                                                                                    ┌──────────────────┐
                                                                                    │ responseBuilder  │
                                                                                    └──────────────────┘
```

The LLM **only** interprets operator notes. It never touches the schedule, never invents demand/solar/tariff values, and its output is treated as untrusted structured data until the guardrail validator passes.

---

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness check. Returns `{"status":"ok"}`. |
| `POST` | `/optimize-energy` | Main entry point. Accepts a scenario JSON, returns directives + 24-hour plan. |

CORS is enabled for all origins.

---

## Request

```json
{
  "scenario_id": "TEST-001",
  "operator_notes": [
    "Solar output will drop to about 20% from 1 PM to 3 PM.",
    "Do not charge the battery between 2 PM and 4 PM.",
    "The cafeteria menu changes tomorrow."
  ],
  "hours": [
    { "hour": 0, "demand_kwh": 180, "solar_kwh": 0, "tariff_bdt_per_kwh": 7 },
    ...
    { "hour": 23, "demand_kwh": 200, "solar_kwh": 0, "tariff_bdt_per_kwh": 9 }
  ],
  "battery": {
    "capacity_kwh": 500,
    "initial_energy_kwh": 200,
    "minimum_energy_kwh": 50,
    "max_charge_kwh_per_hour": 100,
    "max_discharge_kwh_per_hour": 100
  }
}
```

`hours` must contain exactly 24 unique entries (0–23). `operator_notes` must contain 1–3 non-empty strings.

---

## Response

```json
{
  "scenario_id": "TEST-001",
  "directive_interpretation": [
    {
      "note_index": 0,
      "applies": true,
      "directive_type": "solar_reduction",
      "structured_adjustment": { "hours": [13, 14], "factor": 0.2 },
      "explanation": "Solar output drops to 20% remaining from 1 PM to 3 PM."
    },
    {
      "note_index": 1,
      "applies": true,
      "directive_type": "no_charge_window",
      "structured_adjustment": { "hours": [14, 15] },
      "explanation": "Do not charge the battery between 2 PM and 4 PM."
    },
    {
      "note_index": 2,
      "applies": false,
      "directive_type": "no_op",
      "structured_adjustment": null,
      "explanation": "The cafeteria menu change is irrelevant to energy directives."
    }
  ],
  "hourly_plan": [
    {
      "hour": 0,
      "grid_kwh": 180,
      "solar_used_kwh": 0,
      "battery_action": "idle",
      "battery_kwh": 0,
      "battery_energy_after_kwh": 200
    },
    ...
  ],
  "total_grid_kwh": 4318,
  "total_cost_bdt": 45576,
  "peak_grid_kwh": 330,
  "plan_summary": "Total cost 45576.00 BDT; total grid 4318.00 kWh; Charged during hours 2-3; discharged during 9-11, 13; grid import at 0-8, 13-23."
}
```

---

## Supported directive types

| Type | Meaning | `structured_adjustment` |
|---|---|---|
| `solar_reduction` | Reduce usable solar during specific hours | `{ hours: number[], factor: number }` (factor = fraction remaining) |
| `minimum_battery_reserve` | Keep battery at or above a level | `{ hours: number[], minimum_energy_kwh: number }` |
| `no_charge_window` | Battery charging disabled during hours | `{ hours: number[] }` |
| `no_discharge_window` | Battery discharging disabled during hours | `{ hours: number[] }` |
| `max_grid_window` | Cap grid import during hours | `{ hours: number[], max_grid_kwh: number }` |
| `no_op` | Note is irrelevant; no schedule impact | `null` |

**Time window convention:** `start` inclusive, `end` exclusive. `"1 PM to 3 PM"` → `hours: [13, 14]`.

---

## Directive → optimizer mapping

The optimizer applies directives exactly as specified:

| Directive | Effect on the model |
|---|---|
| `solar_reduction` | `effective_solar[h] = original_solar[h] × factor` |
| `minimum_battery_reserve` | `battery_energy_after_kwh[h] ≥ max(base_min, directive_min)` |
| `no_charge_window` | `charge_kwh[h] = 0` |
| `no_discharge_window` | `discharge_kwh[h] = 0` |
| `max_grid_window` | `grid_kwh[h] ≤ max_grid_kwh` |
| `no_op` | No change |

---

## Optimizer pipeline

The optimizer is fully deterministic and runs in six stages:

1. **Effective solar** — apply `solar_reduction` factors.
2. **Constraint overlays** — build per-hour `no_charge`, `no_discharge`, `grid_cap`, and reserve floors.
3. **Backward reachability** — compute the minimum battery energy each hour must retain to satisfy downstream reserve/grid-cap obligations.
4. **Forward greedy** — construct an initial feasible plan discharging into deficit hours up to safe headroom.
5. **Charge creation** — iteratively add `(cheap_hour_charge, expensive_hour_discharge)` pairs that strictly lower cost.
6. **End-of-day neutrality + local 2-opt** — restore `E_final = E_initial` and shift charge/discharge to cheaper/expenser hours until no improving move exists.

Every intermediate state is replayed hour-by-hour by an invariant checker (energy balance, battery bounds, hourly rate limits, solar caps, grid caps, directives) before it can be accepted.

---

## Battery & energy rules

Per hour:

```
charge:    E_after = E_before + battery_kwh
discharge: E_after = E_before − battery_kwh
idle:      E_after = E_before,  battery_kwh = 0
```

Constraints:

- `minimum_energy_kwh ≤ E_after ≤ capacity_kwh`
- `charge_kwh ≤ max_charge_kwh_per_hour`, `discharge_kwh ≤ max_discharge_kwh_per_hour`
- `0 ≤ solar_used_kwh ≤ effective_solar_kwh` (unused solar is curtailed)
- `grid_kwh + solar_used_kwh + battery_discharge_kwh = demand_kwh + battery_charge_kwh`
- `final battery_energy_after_kwh = initial_energy_kwh` (end-of-day neutrality)

---

## LLM integration

**Primary:** Google Gemini (`v1beta/models/{model}:generateContent`) with a JSON response schema.
**Fallback chain:** Gemini `gemini-3.6-flash` → `gemini-3.5-flash-lite` → OpenAI `gpt-4o-mini`.

Model list is hard-coded (not env-driven) so stale models can’t silently break the chain:

```ts
const GEMINI_MODELS = ["gemini-3.6-flash", "gemini-3.5-flash-lite"];
const OPENAI_MODEL  = "gpt-4o-mini";
```

Two Gemini API keys are tried in order before falling through to OpenAI. Every attempt is logged:

```
[fallback] ✅ SUCCESS via gemini:gemini-3.6-flash (key=GEMINI_API_KEY_1, attempt=1, elapsed=812ms)
[interpretNotes] ✅ SUCCESS via gemini:gemini-3.6-flash on attempt 1 (3 note(s) → 3 entries)
```

If the guardrail rejects the LLM output, the interpreter performs **one corrective retry** with the validation errors fed back into the prompt. If the retry also fails, the request returns `422 guardrail_failure`.

---

## Guardrails

The deterministic validator (`guardrailValidator.ts`) rejects any LLM output that:

- doesn’t have exactly one entry per operator note
- uses an unknown `directive_type`
- has `applies=false` on a non-`no_op` directive, or `applies=true` on `no_op`
- has `structured_adjustment=null` on a non-`no_op` directive, or non-null on `no_op`
- has `hours` that aren’t unique integers in `0..23` in strictly ascending order
- has `factor` outside `(0, 1]` on a `solar_reduction`
- has negative `minimum_energy_kwh` or `max_grid_kwh`
- has a missing or empty `explanation`

---

## Deployment

### Prerequisites

- Node.js 18+
- A Cloudflare account with Workers enabled
- At least one of: `GEMINI_API_KEY_1`, `GEMINI_API_KEY_2`, `OPENAI_API_KEY`

### Setup

```bash
git clone https://github.com/<you>/buphackathon.git
cd buphackathon
npm install
```

Create a `wrangler.toml`:

```toml
name = "smart-campus-energy-optimizer"
main = "src/index.ts"
compatibility_date = "2025-01-01"

[vars]
ENVIRONMENT = "production"
```

Set secrets (never commit these):

```bash
wrangler secret put GEMINI_API_KEY_1
wrangler secret put GEMINI_API_KEY_2
wrangler secret put OPENAI_API_KEY
```

### Run locally

```bash
wrangler dev
```

### Deploy

```bash
wrangler deploy
```

### Tail logs

```bash
wrangler tail
```

Watch for `[optimizer:greedy]`, `[optimizer:createCharge]`, `[optimizer:applyNeutrality]`, `[optimizer:localImprovement]` lines — they report how many moves each stage applied and the running cost.

---

## Testing

PowerShell:

```powershell
$body = Get-Content "test.json" -Raw
$response = Invoke-RestMethod `
  -Uri "https://smart-campus-energy-optimizer.asrumon.workers.dev/optimize-energy" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body
$response | ConvertTo-Json -Depth 10
```

`curl`:

```bash
curl -X POST https://<your-worker>.workers.dev/optimize-energy \
  -H "Content-Type: application/json" \
  -d @test.json
```

---

## Project layout

```
src/
  index.ts               Cloudflare Worker entry point, routing, CORS
  types.ts               Shared TypeScript interfaces and ApiError
  validateRequest.ts     Structural validator (400 on malformed input)
  llmInterpreter.ts      Gemini/OpenAI calls, fallback chain, corrective retry
  guardrailValidator.ts  Deterministic LLM-output validator
  optimizer.ts           Six-stage deterministic optimizer
  finalValidator.ts      Hour-by-hour replay validator and totals recompute
  responseBuilder.ts     Assembles the final JSON response
```

---

## Known limitations

- **Optimizer is greedy + 2-opt, not a true LP/MILP solver.** It’s fast and always returns a feasible, directive-compliant plan, but it may leave a few percent of cost on the table versus an exact solution on adversarial scenarios.
- **Single-threaded per request.** Cloudflare Workers have a CPU-time budget; the 2-opt loop is capped at 500 iterations to stay well under it.
- **LLM is not the bottleneck — the deterministic pipeline is.** If interpretation latency ever becomes an issue, the interpreter already caches nothing; every request hits the LLM.

---

## Environment variables

| Name | Required | Purpose |
|---|---|---|
| `GEMINI_API_KEY_1` | recommended | Primary Gemini key |
| `GEMINI_API_KEY_2` | optional | Secondary Gemini key (rate-limit fallback) |
| `OPENAI_API_KEY` | optional | Last-resort provider |
| `ENVIRONMENT` | optional | Free-form tag (e.g., `production`) |

---

## License

Built for the **BUP CSE Fest 2026 Preliminary Round**. Not licensed for commercial redistribution. All scenario data used during development is synthetic.

---

## Acknowledgements

- Problem statement and evaluation rubric: **BUP CSE Fest 2026 Organizing Committee**
- LLM inference: **Google Gemini**, **OpenAI**
- Runtime: **Cloudflare Workers**
