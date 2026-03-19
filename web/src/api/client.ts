import { ForkChoiceResponse, Status, UpstreamsResponse } from '../types';

const API_BASE = '';

async function parseJsonOrThrow<T>(response: Response, context: string): Promise<T> {
  let text: string;
  try {
    text = await response.text();
  } catch {
    throw new Error(`${context}: failed to read response`);
  }
  try {
    return text ? (JSON.parse(text) as T) : ({} as T);
  } catch {
    throw new Error(`${context}: server returned invalid JSON`);
  }
}

function apiError(response: Response): string {
  if (response.status >= 500) return `Server error (${response.status}). The leanpoint backend or upstream may be unavailable.`;
  if (response.status === 404) return 'Not found. The requested resource does not exist.';
  if (response.status === 502) return 'Bad gateway. The upstream did not respond correctly.';
  return `Request failed: ${response.status} ${response.statusText}`;
}

export async function fetchStatus(): Promise<Status> {
  let response: Response;
  try {
    response = await fetch(`${API_BASE}/status`);
  } catch (err) {
    throw new Error('Cannot reach leanpoint API. Check that the server is running and the URL is correct.');
  }
  if (!response.ok) {
    throw new Error(apiError(response));
  }
  return parseJsonOrThrow<Status>(response, 'Status');
}

export async function fetchUpstreams(): Promise<UpstreamsResponse> {
  let response: Response;
  try {
    response = await fetch(`${API_BASE}/api/upstreams`);
  } catch (err) {
    throw new Error('Cannot reach leanpoint API. Check that the server is running and the URL is correct.');
  }
  if (!response.ok) {
    throw new Error(apiError(response));
  }
  return parseJsonOrThrow<UpstreamsResponse>(response, 'Upstreams');
}

export async function fetchHealth(): Promise<{ healthy: boolean }> {
  try {
    const response = await fetch(`${API_BASE}/healthz`);
    return { healthy: response.ok };
  } catch {
    return { healthy: false };
  }
}

function isForkChoiceResponse(value: unknown): value is ForkChoiceResponse {
  if (!value || typeof value !== 'object') return false;
  const o = value as Record<string, unknown>;
  const hasRoot = (x: unknown) => x != null && typeof x === 'object' && typeof (x as { root?: unknown }).root === 'string';
  return (
    hasRoot(o.head) &&
    hasRoot(o.justified) &&
    hasRoot(o.finalized) &&
    hasRoot(o.safe_target) &&
    Array.isArray(o.nodes)
  );
}

export async function fetchForkChoice(upstreamName: string): Promise<ForkChoiceResponse> {
  const encoded = encodeURIComponent(upstreamName);
  let response: Response;
  try {
    response = await fetch(`${API_BASE}/api/upstreams/${encoded}/fork_choice`);
  } catch (err) {
    throw new Error('Cannot reach leanpoint API. Check that the server is running.');
  }
  if (!response.ok) {
    throw new Error(apiError(response));
  }
  const data = await parseJsonOrThrow<unknown>(response, 'Fork choice');
  if (!isForkChoiceResponse(data)) {
    throw new Error('Upstream returned an unsupported fork choice format. This client may not expose the lean fork_choice API.');
  }
  return data;
}
