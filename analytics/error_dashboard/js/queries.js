/**
 * 로컬 Admin SDK 서버 API 클라이언트 (무로그인).
 */

export const PAGE_SIZE = 50;
export const CSV_HARD_CAP = 1000;

async function apiGet(path, params = {}) {
  const url = new URL(path, window.location.origin);
  Object.entries(params).forEach(([k, v]) => {
    if (v === undefined || v === null || v === '') return;
    url.searchParams.set(k, String(v));
  });
  const res = await fetch(url.toString());
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch (_) {
    body = null;
  }
  if (!res.ok) {
    const detail =
      (body && (body.detail || JSON.stringify(body))) || text || res.statusText;
    throw new Error(`${res.status} ${detail}`);
  }
  return body;
}

export function truncate(text, max = 200) {
  const s = (text ?? '').toString();
  if (s.length <= max) return s;
  return `${s.slice(0, max)}…`;
}

export function recipeTitle(row) {
  if (row.recipe && typeof row.recipe === 'object' && row.recipe.title) {
    return String(row.recipe.title);
  }
  return (row.title || '').toString();
}

export async function loadOverview(filters = {}) {
  return apiGet('/api/summary', filters);
}

export async function fetchPage(resourcePath, { cursor = null, limit = PAGE_SIZE, filters = {} } = {}) {
  return apiGet(resourcePath, { cursor, limit, ...filters });
}

export function getGlobalFilterParams() {
  const dateFrom = document.getElementById('global-dateFrom')?.value || '';
  const dateTo = document.getElementById('global-dateTo')?.value || '';
  const order = document.getElementById('global-order')?.value || 'desc';
  const device = document.getElementById('global-device')?.value || 'all';
  return {
    dateFrom: dateFrom || undefined,
    dateTo: dateTo || undefined,
    order,
    device: device === 'all' ? undefined : device,
  };
}

export async function fetchDocById(collectionName, id) {
  return apiGet(`/api/doc/${encodeURIComponent(collectionName)}/${encodeURIComponent(id)}`);
}

export function buildCsv(rows, columns) {
  const escape = (v) => {
    const s = v == null ? '' : String(v);
    if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
  };
  const header = columns.map((c) => escape(c.label)).join(',');
  const lines = rows.map((row) =>
    columns.map((c) => escape(typeof c.value === 'function' ? c.value(row) : row[c.key])).join(','),
  );
  return [header, ...lines].join('\n');
}

export function downloadText(filename, text, mime = 'text/csv;charset=utf-8') {
  const blob = new Blob(['\uFEFF' + text], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

/** resource path map */
export const RESOURCES = {
  errorRecipes: '/api/error-recipes',
  parsingFailures: '/api/parsing-failures',
  recipeReports: '/api/recipe-reports',
  reports: '/api/reports',
  appFeedback: '/api/app-feedback',
  fridgeScan: '/api/fridge-scan-reports',
  priceIssues: '/api/price-issues',
  moderation: '/api/moderation-alerts',
};
