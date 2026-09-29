/**
 * 오류 관찰 대시보드 메인 (로컬 서버, 무로그인)
 */
import {
  PAGE_SIZE,
  CSV_HARD_CAP,
  fetchPage,
  fetchDocById,
  loadOverview,
  recipeTitle,
  truncate,
  buildCsv,
  downloadText,
  RESOURCES,
  getGlobalFilterParams,
} from './queries.js';
import {
  $,
  $all,
  show,
  setText,
  formatCount,
  formatWhen,
  renderKpis,
  renderTable,
  openModal,
  closeModal,
  setStatusBanner,
  setTabError,
  escapeHtml,
} from './ui.js';

let activeTab = 'overview';

const tabState = {
  errorRecipes: { cursor: null, items: [] },
  parsingFailures: { cursor: null, items: [] },
  recipeReports: { cursor: null, items: [] },
  reports: { cursor: null, items: [] },
  appFeedback: { cursor: null, items: [] },
  fridgeScan: { cursor: null, items: [] },
  priceIssues: { cursor: null, items: [] },
  moderation: { cursor: null, items: [] },
};

let overviewLoaded = false;
let chartInstance = null;

function nowLabel() {
  return formatWhen(new Date().toISOString());
}

function linkCell(url, max = 48) {
  const href = (url || '').toString().trim();
  if (!href) return '—';
  const safe = escapeHtml(href);
  const label = escapeHtml(truncate(href, max));
  return `<a href="${safe}" target="_blank" rel="noopener noreferrer" title="${safe}">${label}</a>`;
}

function recipeSourceUrl(row) {
  if (row.sourceUrl) return String(row.sourceUrl);
  if (row.source && typeof row.source === 'object' && row.source.url) {
    return String(row.source.url);
  }
  if (row.url) return String(row.url);
  return '';
}

function deviceLabel(row) {
  const v = (row.appPlatform || row.device || row.clientPlatform || '').toString().trim();
  return v || '—';
}

/** parsing_failures 는 errorType 미기록인 경우가 많아 추론/대체 표시 */
function resolveErrorType(row) {
  const raw = (row.errorType || '').toString().trim();
  if (raw) return raw;
  const reason = (row.reason || '').toString().trim();
  if (reason === 'stuck') return 'stuck';
  const msg = `${row.errorMessage || ''} ${row.error || ''} ${row.note || ''}`.toLowerCase();
  if (!msg.trim()) {
    return reason ? `reason:${reason}` : '—';
  }
  if (msg.includes('not_cooking') || msg.includes('요리가 아')) return 'not_cooking';
  if (msg.includes('insufficient') || msg.includes('부족')) return 'insufficient_info';
  if (msg.includes('video_too_long') || msg.includes('너무 길어')) return 'video_too_long';
  if (msg.includes('concurrent') || msg.includes('동시')) return 'concurrent_limit';
  if (msg.includes('duplicate') || msg.includes('중복')) return 'duplicate';
  if (msg.includes('timeout') || msg.includes('오래 걸려') || msg.includes('timed out')) {
    return 'timeout';
  }
  if (msg.includes('instagram') && (msg.includes('게시물') || msg.includes('reels'))) {
    return 'instagram_invalid';
  }
  if (msg.includes('socket') || msg.includes('host lookup') || msg.includes('network')) {
    return 'network_error';
  }
  if (msg.includes('400') || msg.includes('500') || msg.includes('exception') || msg.includes('server')) {
    return 'server_error';
  }
  return reason ? `reason:${reason}` : 'unknown';
}

function bindShell() {
  show($('#login-view'), false);
  show($('#app-view'), true);
  setText($('#user-email'), '로컬 Admin SDK (로그인 없음)');

  $('#btn-logout')?.remove();
  $('#btn-refresh')?.addEventListener('click', () => refreshActiveTab(true));

  $('#global-apply')?.addEventListener('click', () => {
    clearAllTabState();
    overviewLoaded = false;
    refreshActiveTab(true);
  });
  $('#global-reset')?.addEventListener('click', () => {
    if ($('#global-dateFrom')) $('#global-dateFrom').value = '';
    if ($('#global-dateTo')) $('#global-dateTo').value = '';
    if ($('#global-order')) $('#global-order').value = 'desc';
    if ($('#global-device')) $('#global-device').value = 'all';
    clearAllTabState();
    overviewLoaded = false;
    refreshActiveTab(true);
  });

  $all('.tab-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const tab = btn.dataset.tab;
      if (!tab) return;
      switchTab(tab);
    });
  });

  $('#detail-close')?.addEventListener('click', closeModal);
  $('#detail-modal')?.addEventListener('click', (e) => {
    if (e.target === $('#detail-modal')) closeModal();
  });

  bindListControls('errorRecipes', loadErrorRecipes);
  bindListControls('parsingFailures', loadParsingFailures);
  bindListControls('recipeReports', loadRecipeReports);
  bindListControls('reports', loadReports);
  bindListControls('appFeedback', loadAppFeedback);
  bindListControls('fridgeScan', loadFridgeScan);
  bindListControls('priceIssues', loadPriceIssues);
  bindListControls('moderation', loadModeration);
}

function clearAllTabState() {
  Object.keys(tabState).forEach((k) => {
    tabState[k].cursor = null;
    tabState[k].items = [];
  });
}

function bindListControls(key, loader) {
  $(`#${key}-apply`)?.addEventListener('click', () => {
    tabState[key].cursor = null;
    tabState[key].items = [];
    loader({ reset: true });
  });
  $(`#${key}-next`)?.addEventListener('click', () => loader({ reset: false }));
  $(`#${key}-csv`)?.addEventListener('click', () => exportCsv(key));
}

function switchTab(tab) {
  activeTab = tab;
  $all('.tab-btn').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
  $all('.tab-panel').forEach((p) => show(p, p.dataset.panel === tab));
  refreshActiveTab(false);
}

function refreshActiveTab(force) {
  setText($('#last-refresh'), nowLabel());
  if (activeTab === 'overview') {
    if (force) overviewLoaded = false;
    loadOverviewTab();
    return;
  }
  const map = {
    errorRecipes: loadErrorRecipes,
    parsingFailures: loadParsingFailures,
    recipeReports: loadRecipeReports,
    reports: loadReports,
    appFeedback: loadAppFeedback,
    fridgeScan: loadFridgeScan,
    priceIssues: loadPriceIssues,
    moderation: loadModeration,
  };
  const fn = map[activeTab];
  if (!fn) return;
  if (force) {
    tabState[activeTab].cursor = null;
    tabState[activeTab].items = [];
  }
  if (!tabState[activeTab].items.length || force) {
    fn({ reset: true });
  }
}

async function loadOverviewTab() {
  if (overviewLoaded) return;
  const panel = $('[data-panel="overview"]');
  setTabError(panel, '');
  setText($('#overview-loading'), '집계 중…');
  show($('#overview-loading'), true);

  try {
    const data = await loadOverview(getGlobalFilterParams());
    const counts = data;
    const filt = data.filters || {};
    const deviceNote =
      filt.device && filt.device !== 'all'
        ? `기기=${filt.device} (미지원 탭은 무시)`
        : '';
    const kpiItems = [
      { label: '오류 레시피', value: counts.errorRecipes?.count, hint: counts.errorRecipes?.deviceIgnored ? '기기필터 미지원' : (counts.errorRecipes?.error || 'status=error'), warn: !!counts.errorRecipes?.error },
      { label: '파싱 실패 신고', value: counts.parsingFailures?.count, hint: counts.parsingOpen?.count != null ? `open ${formatCount(counts.parsingOpen.count)}` : (counts.parsingFailures?.error || ''), warn: !!counts.parsingFailures?.error },
      { label: '레시피 문제 제보', value: counts.recipeReports?.count, hint: counts.recipeReports?.deviceIgnored ? '기기필터 미지원' : (counts.recipeReports?.error || ''), warn: !!counts.recipeReports?.error },
      { label: '신고(reports)', value: counts.reports?.count, hint: counts.reportsPending?.count != null ? `pending ${formatCount(counts.reportsPending.count)}` : (counts.reports?.error || ''), warn: !!counts.reports?.error },
      { label: '앱 피드백', value: counts.appFeedback?.count, hint: counts.appFeedback?.error || '', warn: !!counts.appFeedback?.error },
      { label: '스캔 인식 오류', value: counts.fridgeScan?.count, hint: counts.fridgeScan?.error || '', warn: !!counts.fridgeScan?.error },
      { label: '단가 이슈', value: counts.priceIssues?.count, hint: counts.priceIssues?.deviceIgnored ? '기기필터 미지원' : (counts.priceIssues?.error || ''), warn: !!counts.priceIssues?.error },
      { label: '모더레이션 알림', value: counts.moderation?.count, hint: counts.moderation?.deviceIgnored ? '기기필터 미지원' : (counts.moderation?.error || ''), warn: !!counts.moderation?.error },
      { label: '구매인증 큐', value: counts.purchaseQueue?.count, hint: counts.purchaseQueue?.error || '기타', warn: !!counts.purchaseQueue?.error },
    ];
    renderKpis($('#overview-kpis'), kpiItems);
    if (deviceNote || filt.dateFrom || filt.dateTo) {
      setStatusBanner(
        `필터: ${filt.dateFrom || '…'} ~ ${filt.dateTo || '…'} · ${filt.order || 'desc'} · ${deviceNote || '기기=전체'}`,
        'info',
      );
    } else {
      setStatusBanner('');
    }

    const dist = data.distributions || {};
    renderDistTable($('#dist-parsing-reason'), dist.parsingReason, 'reason');
    renderDistTable($('#dist-parsing-platform'), dist.parsingPlatform, 'platform');
    renderDistTable($('#dist-reports-type'), dist.reportsType, 'type');
    renderOverviewChart(dist.parsingPlatform);

    overviewLoaded = true;
    show($('#overview-loading'), false);
  } catch (e) {
    show($('#overview-loading'), false);
    setTabError(panel, e?.message || String(e));
    setStatusBanner('로컬 서버(/api)에 연결하지 못했습니다. server.py로 실행했는지 확인하세요.', 'error');
  }
}

function renderDistTable(el, result, field) {
  if (!el) return;
  if (!result || result.error) {
    el.innerHTML = `<p class="muted">오류: ${escapeHtml(result?.error || '없음')}</p>`;
    return;
  }
  const entries = Object.entries(result.dist || {}).sort((a, b) => b[1] - a[1]);
  if (!entries.length) {
    el.innerHTML = '<p class="muted">샘플 없음</p>';
    return;
  }
  el.innerHTML = `
    <p class="muted">최근 ${result.sampleSize}건 샘플 · 필드 ${escapeHtml(field)}</p>
    <table class="mini"><thead><tr><th>값</th><th>건수</th></tr></thead>
    <tbody>${entries
      .map(([k, v]) => `<tr><td>${escapeHtml(k)}</td><td>${formatCount(v)}</td></tr>`)
      .join('')}</tbody></table>`;
}

function renderOverviewChart(pfPlatform) {
  const canvas = $('#overview-chart');
  if (!canvas || typeof Chart === 'undefined') return;
  const labels = Object.keys(pfPlatform?.dist || {});
  const data = Object.values(pfPlatform?.dist || {});
  if (chartInstance) {
    chartInstance.destroy();
    chartInstance = null;
  }
  if (!labels.length) return;
  chartInstance = new Chart(canvas, {
    type: 'bar',
    data: {
      labels,
      datasets: [{ label: 'parsing_failures platform (sample)', data, backgroundColor: '#2f6fed' }],
    },
    options: {
      responsive: true,
      plugins: { legend: { display: false } },
      scales: { y: { beginAtZero: true, ticks: { precision: 0 } } },
    },
  });
}

async function loadList({
  key,
  panelSel,
  resource,
  collectionName,
  tbodySel,
  metaSel,
  reset,
  columns,
  serverFilters = {},
  clientFilter = (x) => x,
}) {
  const panel = $(panelSel);
  const st = tabState[key];
  setTabError(panel, '');
  try {
    const page = await fetchPage(resource, {
      cursor: reset ? null : st.cursor,
      limit: PAGE_SIZE,
      filters: { ...getGlobalFilterParams(), ...serverFilters },
    });
    const filtered = clientFilter(page.items || []);
    st.cursor = page.nextCursor || null;
    st.items = reset ? filtered : st.items.concat(filtered);
    renderTable($(tbodySel), st.items, columns, (row) => openDetail(collectionName, row.id, row));
    const warn =
      Array.isArray(page.warnings) && page.warnings.includes('device_filter_not_supported')
        ? ' · 기기필터 미지원(무시됨)'
        : '';
    setText(
      $(metaSel),
      `${formatCount(st.items.length)}건 표시 · 다음 ${st.cursor ? '있음' : '끝'}${warn}`,
    );
  } catch (e) {
    setTabError(panel, e?.message || String(e));
  }
}

async function loadErrorRecipes({ reset }) {
  const errorType = $('#errorRecipes-errorType')?.value?.trim() || '';
  const hidden = $('#errorRecipes-hidden')?.value || '';
  const qtext = ($('#errorRecipes-q')?.value || '').trim().toLowerCase();

  await loadList({
    key: 'errorRecipes',
    panelSel: '[data-panel="errorRecipes"]',
    resource: RESOURCES.errorRecipes,
    collectionName: 'recipes',
    tbodySel: '#errorRecipes-tbody',
    metaSel: '#errorRecipes-meta',
    reset,
    clientFilter: (items) => {
      let rows = items;
      if (errorType) rows = rows.filter((r) => (r.errorType || '') === errorType);
      if (hidden === 'true') rows = rows.filter((r) => r.isHidden === true);
      if (hidden === 'false') rows = rows.filter((r) => r.isHidden !== true);
      if (qtext) {
        rows = rows.filter((r) => {
          const hay = `${recipeTitle(r)} ${r.error || ''} ${r.id} ${recipeSourceUrl(r)} ${r.userId || ''}`.toLowerCase();
          return hay.includes(qtext);
        });
      }
      return rows;
    },
    columns: [
      { key: 'updatedAt', label: 'updatedAt', render: (r) => escapeHtml(formatWhen(r.updatedAt)) },
      { key: 'title', label: '제목', render: (r) => escapeHtml(truncate(recipeTitle(r) || '(제목 없음)', 36)) },
      { key: 'errorType', label: 'errorType', render: (r) => escapeHtml(r.errorType || '—') },
      { key: 'sourceUrl', label: '영상 URL', render: (r) => linkCell(recipeSourceUrl(r), 42) },
      { key: 'userId', label: 'userId', render: (r) => `<code title="${escapeHtml(r.userId || '')}">${escapeHtml(truncate(r.userId || '—', 18))}</code>` },
      {
        key: 'appPlatform',
        label: '기기',
        render: (r) => {
          const label = deviceLabel(r);
          const inferred = r._appPlatformSource === 'parsing_failures';
          return inferred && label !== '—'
            ? `<span title="parsing_failures에서 보강">${escapeHtml(label)}*</span>`
            : escapeHtml(label);
        },
      },
      { key: 'error', label: 'error', render: (r) => escapeHtml(truncate(r.error || '', 64)) },
      { key: 'isHidden', label: 'hidden', render: (r) => (r.isHidden === true ? 'Y' : '') },
    ],
  });
}

async function loadParsingFailures({ reset }) {
  const reason = $('#parsingFailures-reason')?.value || '';
  const status = $('#parsingFailures-status')?.value || '';
  const platform = ($('#parsingFailures-platform')?.value || '').trim();
  const kind = $('#parsingFailures-kind')?.value || '';

  await loadList({
    key: 'parsingFailures',
    panelSel: '[data-panel="parsingFailures"]',
    resource: RESOURCES.parsingFailures,
    collectionName: 'parsing_failures',
    tbodySel: '#parsingFailures-tbody',
    metaSel: '#parsingFailures-meta',
    reset,
    serverFilters: { status, reason: status ? '' : reason },
    clientFilter: (items) => {
      let rows = items;
      if (reason) rows = rows.filter((r) => r.reason === reason);
      if (status) rows = rows.filter((r) => (r.status || 'open') === status);
      if (kind) rows = rows.filter((r) => r.kind === kind);
      if (platform) rows = rows.filter((r) => (r.platform || '') === platform);
      return rows;
    },
    columns: [
      { key: 'createdAt', label: '시간', render: (r) => escapeHtml(formatWhen(r.createdAt)) },
      { key: 'reason', label: 'reason', render: (r) => escapeHtml(r.reason || '') },
      { key: 'platform', label: 'platform', render: (r) => escapeHtml(r.platform || '—') },
      { key: 'sourceUrl', label: '영상 URL', render: (r) => linkCell(r.sourceUrl || '', 42) },
      { key: 'userId', label: 'userId', render: (r) => `<code title="${escapeHtml(r.userId || '')}">${escapeHtml(truncate(r.userId || '—', 18))}</code>` },
      { key: 'appPlatform', label: '기기', render: (r) => escapeHtml(deviceLabel(r)) },
      {
        key: 'errorType',
        label: 'errorType',
        render: (r) => {
          const shown = resolveErrorType(r);
          const stored = (r.errorType || '').toString().trim();
          const mark = stored ? '' : ' (추정)';
          return `<span title="${escapeHtml(r.errorMessage || r.error || '')}">${escapeHtml(shown)}${escapeHtml(mark)}</span>`;
        },
      },
      {
        key: 'errorMessage',
        label: 'errorMessage',
        render: (r) => escapeHtml(truncate(r.errorMessage || r.error || r.note || '', 56)),
      },
      { key: 'status', label: 'status', render: (r) => escapeHtml(r.status || '') },
    ],
  });
}

async function loadRecipeReports({ reset }) {
  const qtext = ($('#recipeReports-q')?.value || '').trim().toLowerCase();
  await loadList({
    key: 'recipeReports',
    panelSel: '[data-panel="recipeReports"]',
    resource: RESOURCES.recipeReports,
    collectionName: 'recipe_reports',
    tbodySel: '#recipeReports-tbody',
    metaSel: '#recipeReports-meta',
    reset,
    clientFilter: (items) => {
      if (!qtext) return items;
      return items.filter((r) =>
        `${r.recipeTitle || ''} ${r.message || ''} ${r.recipeId || ''}`.toLowerCase().includes(qtext),
      );
    },
    columns: [
      { key: 'createdAt', label: '시간', render: (r) => escapeHtml(formatWhen(r.createdAt)) },
      { key: 'recipeTitle', label: '제목', render: (r) => escapeHtml(truncate(r.recipeTitle || '', 40)) },
      { key: 'message', label: 'message', render: (r) => escapeHtml(truncate(r.message || '', 80)) },
      { key: 'recipeId', label: 'recipeId', render: (r) => `<code>${escapeHtml(truncate(r.recipeId || '', 14))}</code>` },
      { key: 'userId', label: 'userId', render: (r) => escapeHtml(truncate(r.userId || '', 12)) },
    ],
  });
}

async function loadReports({ reset }) {
  const type = $('#reports-type')?.value || '';
  const status = $('#reports-status')?.value || '';
  await loadList({
    key: 'reports',
    panelSel: '[data-panel="reports"]',
    resource: RESOURCES.reports,
    collectionName: 'reports',
    tbodySel: '#reports-tbody',
    metaSel: '#reports-meta',
    reset,
    serverFilters: { status, type: status ? '' : type },
    clientFilter: (items) => {
      let rows = items;
      if (type) rows = rows.filter((r) => r.type === type);
      if (status) rows = rows.filter((r) => r.status === status);
      return rows;
    },
    columns: [
      { key: 'createdAt', label: '시간', render: (r) => escapeHtml(formatWhen(r.createdAt)) },
      { key: 'type', label: 'type', render: (r) => escapeHtml(r.type || '') },
      { key: 'reason', label: 'reason', render: (r) => escapeHtml(r.reason || '') },
      { key: 'status', label: 'status', render: (r) => escapeHtml(r.status || '') },
      { key: 'targetId', label: 'targetId', render: (r) => escapeHtml(truncate(r.targetId || '', 24)) },
      { key: 'description', label: 'desc', render: (r) => escapeHtml(truncate(r.description || '', 60)) },
    ],
  });
}

async function loadAppFeedback({ reset }) {
  const cat = ($('#appFeedback-category')?.value || '').trim();
  const platform = ($('#appFeedback-platform')?.value || '').trim();
  await loadList({
    key: 'appFeedback',
    panelSel: '[data-panel="appFeedback"]',
    resource: RESOURCES.appFeedback,
    collectionName: 'app_feedback',
    tbodySel: '#appFeedback-tbody',
    metaSel: '#appFeedback-meta',
    reset,
    clientFilter: (items) => {
      let rows = items;
      if (cat) rows = rows.filter((r) => (r.categories || []).includes(cat));
      if (platform) rows = rows.filter((r) => (r.platform || '') === platform);
      return rows;
    },
    columns: [
      { key: 'createdAt', label: '시간', render: (r) => escapeHtml(formatWhen(r.createdAt)) },
      { key: 'categories', label: 'categories', render: (r) => escapeHtml((r.categories || []).join(', ')) },
      { key: 'detail', label: 'detail', render: (r) => escapeHtml(truncate(r.detail || '', 80)) },
      { key: 'liked', label: 'liked', render: (r) => escapeHtml(truncate(r.liked || '', 40)) },
      { key: 'disliked', label: 'disliked', render: (r) => escapeHtml(truncate(r.disliked || '', 40)) },
      { key: 'platform', label: 'platform', render: (r) => escapeHtml(r.platform || '') },
    ],
  });
}

async function loadFridgeScan({ reset }) {
  const reason = $('#fridgeScan-reason')?.value || '';
  const status = $('#fridgeScan-status')?.value || '';
  await loadList({
    key: 'fridgeScan',
    panelSel: '[data-panel="fridgeScan"]',
    resource: RESOURCES.fridgeScan,
    collectionName: 'fridge_scan_reports',
    tbodySel: '#fridgeScan-tbody',
    metaSel: '#fridgeScan-meta',
    reset,
    serverFilters: { status },
    clientFilter: (items) => {
      let rows = items;
      if (reason) rows = rows.filter((r) => r.reason === reason);
      if (status) rows = rows.filter((r) => (r.status || 'open') === status);
      return rows;
    },
    columns: [
      { key: 'createdAt', label: '시간', render: (r) => escapeHtml(formatWhen(r.createdAt)) },
      { key: 'reason', label: 'reason', render: (r) => escapeHtml(r.reason || '') },
      { key: 'photoType', label: 'photoType', render: (r) => escapeHtml(r.photoType || '') },
      { key: 'focusItemName', label: 'focus', render: (r) => escapeHtml(r.focusItemName || '') },
      { key: 'note', label: 'note', render: (r) => escapeHtml(truncate(r.note || '', 60)) },
      { key: 'status', label: 'status', render: (r) => escapeHtml(r.status || '') },
    ],
  });
}

async function loadPriceIssues({ reset }) {
  const qtext = ($('#priceIssues-q')?.value || '').trim().toLowerCase();
  await loadList({
    key: 'priceIssues',
    panelSel: '[data-panel="priceIssues"]',
    resource: RESOURCES.priceIssues,
    collectionName: 'ingredient_price_issue_reports',
    tbodySel: '#priceIssues-tbody',
    metaSel: '#priceIssues-meta',
    reset,
    clientFilter: (items) => {
      if (!qtext) return items;
      return items.filter((r) => {
        const names = (r.ingredientNames || []).join(' ');
        return `${names} ${r.message || ''} ${r.recipeId || ''} ${r.recipeTitle || ''}`.toLowerCase().includes(qtext);
      });
    },
    columns: [
      { key: 'createdAt', label: '시간', render: (r) => escapeHtml(formatWhen(r.createdAt)) },
      { key: 'ingredientNames', label: '재료', render: (r) => escapeHtml(truncate((r.ingredientNames || []).join(', '), 48)) },
      { key: 'message', label: 'message', render: (r) => escapeHtml(truncate(r.message || '', 60)) },
      { key: 'recipeTitle', label: '레시피', render: (r) => escapeHtml(truncate(r.recipeTitle || '', 32)) },
      { key: 'recipeId', label: 'recipeId', render: (r) => `<code>${escapeHtml(truncate(r.recipeId || '', 12))}</code>` },
    ],
  });
}

async function loadModeration({ reset }) {
  const eventType = $('#moderation-eventType')?.value || '';
  await loadList({
    key: 'moderation',
    panelSel: '[data-panel="moderation"]',
    resource: RESOURCES.moderation,
    collectionName: 'moderation_alerts',
    tbodySel: '#moderation-tbody',
    metaSel: '#moderation-meta',
    reset,
    serverFilters: { eventType },
    clientFilter: (items) => {
      if (!eventType) return items;
      return items.filter((r) => r.eventType === eventType);
    },
    columns: [
      { key: 'createdAt', label: '시간', render: (r) => escapeHtml(formatWhen(r.createdAt)) },
      { key: 'eventType', label: 'eventType', render: (r) => escapeHtml(r.eventType || '') },
      { key: 'reason', label: 'reason', render: (r) => escapeHtml(truncate(r.reason || '', 48)) },
      { key: 'reportId', label: 'reportId', render: (r) => escapeHtml(truncate(r.reportId || '', 12)) },
      { key: 'reviewId', label: 'reviewId', render: (r) => escapeHtml(truncate(r.reviewId || '', 12)) },
      { key: 'targetUserId', label: 'targetUser', render: (r) => escapeHtml(truncate(r.targetUserId || '', 12)) },
    ],
  });
}

async function openDetail(collectionName, id, fallback) {
  try {
    const fresh = await fetchDocById(collectionName, id);
    openModal(`${collectionName}/${id}`, fresh || fallback);
  } catch (e) {
    openModal(`${collectionName}/${id}`, { ...fallback, _fetchError: e?.message || String(e) });
  }
}

async function exportCsv(key) {
  const st = tabState[key];
  if (!st?.items?.length) {
    setStatusBanner('내보낼 행이 없습니다. 먼저 목록을 로드하세요.', 'error');
    return;
  }
  const rows = st.items.slice(0, CSV_HARD_CAP);
  const columns = Object.keys(rows[0]).map((k) => ({
    key: k,
    label: k,
    value: (r) => {
      const v = r[k];
      if (v == null) return '';
      if (typeof v === 'object') return JSON.stringify(v);
      return String(v);
    },
  }));
  downloadText(`yorigo_${key}_${Date.now()}.csv`, buildCsv(rows, columns));
  setStatusBanner(`${rows.length}행 CSV 다운로드`, 'info');
  setTimeout(() => setStatusBanner(''), 2500);
}

bindShell();
switchTab('overview');
