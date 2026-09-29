/**
 * DOM / 테이블 / 모달 유틸
 */

export function $(sel, root = document) {
  return root.querySelector(sel);
}

export function $all(sel, root = document) {
  return [...root.querySelectorAll(sel)];
}

export function setText(el, text) {
  if (el) el.textContent = text ?? '';
}

export function show(el, visible) {
  if (!el) return;
  el.hidden = !visible;
}

export function formatCount(n) {
  if (n == null || Number.isNaN(n)) return '—';
  return Number(n).toLocaleString('ko-KR');
}

export function formatWhen(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const pad = (x) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function renderKpis(container, items) {
  container.innerHTML = items
    .map(
      (it) => `
    <div class="kpi ${it.warn ? 'kpi-warn' : ''}">
      <div class="kpi-label">${escapeHtml(it.label)}</div>
      <div class="kpi-value">${escapeHtml(formatCount(it.value))}</div>
      ${it.hint ? `<div class="kpi-hint">${escapeHtml(it.hint)}</div>` : ''}
    </div>`,
    )
    .join('');
}

export function escapeHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * @param {HTMLElement} tbody
 * @param {object[]} rows
 * @param {{key:string, label:string, render?:(row)=>string}[]} columns
 * @param {(row)=>void} onRowClick
 */
export function renderTable(tbody, rows, columns, onRowClick) {
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="${columns.length}" class="empty">데이터 없음</td></tr>`;
    return;
  }
  tbody.innerHTML = rows
    .map((row, idx) => {
      const cells = columns
        .map((c) => {
          const html = c.render ? c.render(row) : escapeHtml(row[c.key] ?? '');
          return `<td>${html}</td>`;
        })
        .join('');
      return `<tr data-idx="${idx}" class="clickable">${cells}</tr>`;
    })
    .join('');

  $all('tr.clickable', tbody).forEach((tr) => {
    tr.addEventListener('click', () => {
      const idx = Number(tr.dataset.idx);
      onRowClick?.(rows[idx]);
    });
  });
}

export function openModal(title, obj) {
  const modal = $('#detail-modal');
  const titleEl = $('#detail-title');
  const bodyEl = $('#detail-body');
  setText(titleEl, title);
  bodyEl.textContent = JSON.stringify(obj, null, 2);
  show(modal, true);
}

export function closeModal() {
  show($('#detail-modal'), false);
}

export function setStatusBanner(message, kind = 'info') {
  const el = $('#status-banner');
  if (!el) return;
  if (!message) {
    show(el, false);
    return;
  }
  el.className = `status-banner status-${kind}`;
  setText(el, message);
  show(el, true);
}

export function setTabError(panel, message) {
  const err = panel?.querySelector('.tab-error');
  if (!err) return;
  if (!message) {
    show(err, false);
    setText(err, '');
    return;
  }
  setText(err, message);
  show(err, true);
}
