// ============================================================================
// src/index.ts â€” Cloudflare Worker entry point.
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