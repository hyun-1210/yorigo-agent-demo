const $ = (id) => document.getElementById(id);

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

function toast(msg, ok = true) {
  const el = $("toast");
  el.hidden = false;
  el.textContent = msg;
  el.style.borderColor = ok ? "#22c55e" : "#ef4444";
  setTimeout(() => { el.hidden = true; }, 2800);
}

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    ...opts,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || data.error || res.statusText);
  return data;
}

let posters = [];
let sections = [];
let selectedPoster = null;
let selectedSection = null;
let posterIndex = 0;
let posterChipIndex = 0;
let homeKind = "program";
let homeKey = "";
const previewCache = new Map();

function enabledPosters() {
  return posters.filter((p) => p.enabled !== false).sort((a, b) => (a.order || 0) - (b.order || 0));
}

function programSections() {
  return sections.filter((s) => s.kind === "program" && s.enabled !== false);
}

function homeFeedSections() {
  return sections.filter((s) => (s.kind === "trend" || s.kind === "moment") && s.enabled !== false);
}

function posterImageSrc(p) {
  const url = (p.imageUrl || "").trim();
  if (url.startsWith("http")) return url;
  const asset = (p.assetPath || "").replace(/\\/g, "/");
  if (asset.startsWith("assets/images/home_poster_")) {
    return `/api/local-asset?path=${encodeURIComponent(asset)}`;
  }
  return "";
}

function switchTab(name) {
  document.querySelectorAll(".tab").forEach((t) => {
    t.classList.toggle("active", t.dataset.tab === name);
  });
  $("tab-posters").hidden = name !== "posters";
  $("tab-sections").hidden = name !== "sections";
  $("tab-recipes").hidden = name !== "recipes";
  if (name === "posters") renderPosterStage();
  if (name === "sections") renderHomeStage();
}

document.querySelectorAll(".tab").forEach((t) => {
  t.addEventListener("click", () => switchTab(t.dataset.tab));
});

function curationOptions() {
  const items = [];
  const seen = new Set();
  for (const s of sections) {
    if (!s.sectionKey || seen.has(s.sectionKey)) continue;
    seen.add(s.sectionKey);
    items.push({ key: s.sectionKey, label: s.label || s.sectionKey });
  }
  for (const p of posters) {
    const posterName = (p.posterTitle || p.id || "").replace(/\n/g, " ");
    for (const chip of p.chips || []) {
      const key = chip.sectionKey;
      if (!key || seen.has(key)) continue;
      seen.add(key);
      items.push({ key, label: `${chip.label} · ${posterName}` });
    }
  }
  return items;
}

function fillCurationKeys(preferred) {
  const sel = $("curationKey");
  const current = preferred || sel.value;
  const opts = curationOptions();
  sel.innerHTML = opts.map((o) =>
    `<option value="${esc(o.key)}">${esc(o.label)}</option>`
  ).join("");
  if (current && opts.some((o) => o.key === current)) sel.value = current;
}

function openCuration(key, label) {
  if (!key) {
    toast("이 칩은 공통 풀+키워드라 전용 목록이 없습니다", false);
    return;
  }
  fillCurationKeys(key);
  $("curationKey").value = key;
  $("curationHint").textContent = label
    ? `「${label}」 목록을 편집합니다`
    : "레시피를 검색해 넣거나 빼면 앱 미리보기에 반영됩니다";
  switchTab("recipes");
  loadIndex();
}

async function loadPreview(key) {
  if (!key) return { count: 0, recipes: [] };
  if (previewCache.has(key)) return previewCache.get(key);
  const data = await api(`/api/preview/section?section_key=${encodeURIComponent(key)}&limit=8`);
  previewCache.set(key, data);
  return data;
}

function recipeCardsHtml(recipes) {
  if (!recipes || !recipes.length) {
    return `<div class="empty-row">아직 레시피가 없습니다. 「이 목록 편집」에서 추가하세요.</div>`;
  }
  return `<div class="cards">${recipes.map((r) => `
    <div class="recipe-card">
      ${r.thumbnailUrl
        ? `<img class="thumb" src="${esc(r.thumbnailUrl)}" alt="" />`
        : `<div class="thumb"></div>`}
      <div class="title">${esc(r.title)}</div>
    </div>`).join("")}</div>`;
}

function renderPosterStage() {
  const list = enabledPosters();
  if (!list.length) {
    $("posterStage").innerHTML = `<div class="empty-row">노출 중인 포스터가 없습니다</div>`;
    return;
  }
  if (posterIndex >= list.length) posterIndex = 0;
  const p = list[posterIndex];
  selectedPoster = posters.find((x) => x.id === p.id) || p;
  const chips = p.chips || [];
  if (posterChipIndex >= chips.length) posterChipIndex = 0;
  const chip = chips[posterChipIndex] || {};
  const src = posterImageSrc(p);
  $("posterStage").innerHTML = `
    <div class="poster-card" id="posterHero">
      ${src ? `<img src="${esc(src)}" alt="" />` : `<div class="poster-fallback"></div>`}
      <div class="poster-copy">
        <h2>${esc(p.posterTitle || "")}</h2>
        <p>${esc(p.subtitle || "")}</p>
      </div>
      <div class="poster-count">${posterIndex + 1} / ${list.length} ›</div>
    </div>
    <div class="dots">${list.map((_, i) =>
      `<button data-dot="${i}" class="${i === posterIndex ? "on" : ""}"></button>`
    ).join("")}</div>
    <div class="detail-sheet">
      <span class="eyebrow">${esc(p.eyebrow || "요리고 큐레이션")}</span>
      <h3 class="detail-title">${esc(p.pageTitle || (p.posterTitle || "").replace(/\n/g, " "))}</h3>
      <p class="detail-body">${esc(p.body || "")}</p>
      ${(p.tips || []).length
        ? `<div class="tips">${(p.tips || []).map((t) =>
            `<div class="tip"><b>${esc(t.title || "")}</b><p>${esc(t.body || "")}</p></div>`
          ).join("")}</div>`
        : ""}
    </div>
    <div class="chips">${chips.map((c, i) =>
      `<button data-chip="${i}" class="${i === posterChipIndex ? "on" : ""}">${esc(c.label)}</button>`
    ).join("")}</div>
    <div id="posterRecipes"><div class="empty-row">레시피 불러오는 중…</div></div>
    ${chip.sectionKey
      ? ""
      : `<div class="note">이 칩은 키워드 필터입니다. 앱에서는 공통 풀에서 한 번 더 걸러집니다.</div>`}
    <div class="phone-body">
      <div style="padding:0 16px">
        <button data-edit-chip>이 목록 편집</button>
      </div>
    </div>
  `;
  $("posterHero").onclick = () => {
    posterIndex = (posterIndex + 1) % list.length;
    posterChipIndex = 0;
    renderPosterStage();
    renderPosterPicker();
    renderPosterLite();
  };
  $("posterStage").querySelectorAll("[data-dot]").forEach((btn) => {
    btn.onclick = (ev) => {
      ev.stopPropagation();
      posterIndex = Number(btn.dataset.dot);
      posterChipIndex = 0;
      renderPosterStage();
      renderPosterPicker();
      renderPosterLite();
    };
  });
  $("posterStage").querySelectorAll("[data-chip]").forEach((btn) => {
    btn.onclick = () => {
      posterChipIndex = Number(btn.dataset.chip);
      renderPosterStage();
    };
  });
  const editBtn = $("posterStage").querySelector("[data-edit-chip]");
  if (editBtn) {
    editBtn.onclick = () => openCuration(
      chip.sectionKey || (p.poolSectionKeys || [])[0],
      chip.label,
    );
  }
  const previewKey = chip.sectionKey || (p.poolSectionKeys || [])[0] || "";
  loadPreview(previewKey).then((data) => {
    const box = $("posterRecipes");
    if (box) box.innerHTML = recipeCardsHtml(data.recipes);
  }).catch((e) => toast(String(e.message || e), false));
}

function renderPosterPicker() {
  const list = enabledPosters();
  $("posterPicker").innerHTML =
    `<b>홈 포스터</b><div class="muted">앱 상단 캐러셀에 이렇게 보입니다</div>` +
    posters.map((p) => {
      const src = posterImageSrc(p);
      const on = selectedPoster && selectedPoster.id === p.id ? " on" : "";
      return `<div class="pick${on}" data-id="${esc(p.id)}">
        ${src ? `<img src="${esc(src)}" alt="" />` : `<div class="mini"></div>`}
        <div>
          <b>${esc((p.posterTitle || p.id).replace(/\n/g, " "))}</b>
          <div class="muted">${p.enabled === false ? "숨김" : "노출"} · 칩 ${(p.chips || []).length}개</div>
        </div>
      </div>`;
    }).join("") +
    `<div class="actions"><button class="ghost" id="btnNewPoster">포스터 추가</button></div>`;
  $("posterPicker").querySelectorAll(".pick").forEach((el) => {
    el.onclick = () => {
      selectedPoster = posters.find((p) => p.id === el.dataset.id);
      const vis = enabledPosters();
      const idx = vis.findIndex((p) => p.id === el.dataset.id);
      posterIndex = idx >= 0 ? idx : posterIndex;
      posterChipIndex = 0;
      renderPosterStage();
      renderPosterPicker();
      renderPosterLite();
    };
  });
  $("btnNewPoster").onclick = () => {
    selectedPoster = {
      id: "",
      enabled: true,
      order: posters.length,
      posterTitle: "",
      subtitle: "",
      pageTitle: "",
      body: "",
      eyebrow: "요리고 큐레이션",
      chips: [{ label: "전체", sectionKey: "", matchKeywords: [] }],
      poolSectionKeys: [],
      tips: [],
      products: [],
      imageAlignment: "centerRight",
    };
    renderPosterLite();
  };
}

function renderPosterLite() {
  const p = selectedPoster;
  if (!p) {
    $("posterLiteEdit").innerHTML = `<div class="muted">왼쪽 미리보기에서 포스터를 고르세요</div>`;
    return;
  }
  $("posterLiteEdit").innerHTML = `
    <b>글자·이미지</b>
    ${p.id ? "" : `<label>id (영문)</label><input id="p_id" value="" />`}
    <label>홈 큰 제목</label>
    <textarea id="p_title">${esc(p.posterTitle || "")}</textarea>
    <label>홈 부제</label>
    <input id="p_sub" value="${esc(p.subtitle || "")}" />
    <label>상세 배지 (예: 여름 메뉴 큐레이션)</label>
    <input id="p_eye" value="${esc(p.eyebrow || "")}" />
    <label>상세 제목</label>
    <input id="p_page" value="${esc(p.pageTitle || "")}" />
    <label>상세 본문</label>
    <textarea id="p_body">${esc(p.body || "")}</textarea>
    <label>노출</label>
    <select id="p_enabled">
      <option value="true" ${p.enabled !== false ? "selected" : ""}>보이기</option>
      <option value="false" ${p.enabled === false ? "selected" : ""}>숨기기</option>
    </select>
    <label>이미지 바꾸기</label>
    <input id="p_file" type="file" accept="image/*" ${p.id ? "" : "disabled"} />
    <div class="actions">
      <button id="p_save">저장</button>
      ${p.id ? `<button class="danger" id="p_del">삭제</button>` : ""}
    </div>
    <details class="adv"><summary>안내 카드 (팁)</summary>
      ${(p.tips || []).map((t, i) =>
        `<label>팁 ${i + 1} 제목</label>
         <input data-tip-title="${i}" value="${esc(t.title || "")}" />
         <label>팁 ${i + 1} 본문</label>
         <textarea data-tip-body="${i}">${esc(t.body || "")}</textarea>`
      ).join("") || `<div class="muted">등록된 팁이 없습니다</div>`}
    </details>
    <details class="adv"><summary>칩 이름 (고급)</summary>
      <div class="muted">레시피 목록은 큐레이션 탭에서 바꿉니다</div>
      ${(p.chips || []).map((c, i) =>
        `<label>${esc(c.sectionKey || "키워드칩")}</label>
         <input data-chip-label="${i}" value="${esc(c.label || "")}" />`
      ).join("")}
    </details>
  `;
  $("p_save").onclick = savePosterLite;
  const del = $("p_del");
  if (del) del.onclick = deletePoster;
  $("p_file").onchange = uploadPosterImage;
}

async function savePosterLite() {
  try {
    const p = selectedPoster || {};
    const chips = (p.chips || []).map((c, i) => {
      const input = document.querySelector(`[data-chip-label="${i}"]`);
      return { ...c, label: input ? input.value.trim() || c.label : c.label };
    });
    const tips = (p.tips || []).map((t, i) => {
      const titleEl = document.querySelector(`[data-tip-title="${i}"]`);
      const bodyEl = document.querySelector(`[data-tip-body="${i}"]`);
      return {
        ...t,
        title: titleEl ? titleEl.value.trim() : t.title,
        body: bodyEl ? bodyEl.value.trim() : t.body,
      };
    });
    const payload = {
      ...p,
      id: p.id || ($("p_id") ? $("p_id").value.trim() : ""),
      posterTitle: $("p_title").value,
      subtitle: $("p_sub").value,
      eyebrow: $("p_eye").value,
      pageTitle: $("p_page").value || $("p_title").value.replace(/\n/g, " "),
      body: $("p_body").value,
      enabled: $("p_enabled").value === "true",
      chips,
      tips,
    };
    if (!payload.id) throw new Error("id가 필요합니다");
    const exists = posters.some((x) => x.id === payload.id);
    const data = exists
      ? await api(`/api/posters/${payload.id}`, { method: "PUT", body: JSON.stringify(payload) })
      : await api("/api/posters", { method: "POST", body: JSON.stringify(payload) });
    toast("포스터 저장됨 · 디버그 앱을 다시 열면 글자가 바뀝니다");
    selectedPoster = data.poster;
    previewCache.clear();
    await loadAll();
  } catch (e) {
    toast(String(e.message || e), false);
  }
}

async function deletePoster() {
  if (!selectedPoster?.id) return;
  if (!confirm("이 포스터를 삭제할까요?")) return;
  try {
    await api(`/api/posters/${selectedPoster.id}`, { method: "DELETE" });
    selectedPoster = null;
    toast("삭제됨");
    previewCache.clear();
    await loadAll();
  } catch (e) {
    toast(String(e.message || e), false);
  }
}

async function uploadPosterImage(ev) {
  const file = ev.target.files && ev.target.files[0];
  if (!file || !selectedPoster?.id) return;
  const fd = new FormData();
  fd.append("file", file);
  try {
    const res = await fetch(`/api/posters/${selectedPoster.id}/image`, { method: "POST", body: fd });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "upload failed");
    toast("이미지 업로드됨");
    previewCache.clear();
    await loadAll();
    selectedPoster = posters.find((p) => p.id === selectedPoster.id);
    renderPosterLite();
  } catch (e) {
    toast(String(e.message || e), false);
  }
}

function renderHomeStage() {
  const programs = programSections();
  const trends = homeFeedSections();
  if (!homeKey) {
    homeKey = (homeKind === "program" ? programs[0] : trends[0])?.sectionKey || "";
  }
  const currentList = homeKind === "program" ? programs : trends;
  const current = currentList.find((s) => s.sectionKey === homeKey) || currentList[0];
  if (current) {
    homeKey = current.sectionKey;
    selectedSection = current;
  }
  $("homeStage").innerHTML = `
    <div class="section-head"><b>TV에서 본 그 레시피</b><span>전체보기 ›</span></div>
    <div class="chips">${programs.map((s) =>
      `<button data-kind="program" data-key="${esc(s.sectionKey)}" class="${homeKind === "program" && s.sectionKey === homeKey ? "on" : ""}">${esc(s.label)}</button>`
    ).join("") || `<div class="empty-row">프로그램 카테고리가 없습니다</div>`}</div>
    <div id="homeProgramCards">${homeKind === "program" ? `<div class="empty-row">레시피 불러오는 중…</div>` : ""}</div>
    <div class="section-head"><b>홈 카테고리</b><span>트렌드·모먼트</span></div>
    <div class="chips">${trends.map((s) =>
      `<button data-kind="trend" data-key="${esc(s.sectionKey)}" class="${homeKind !== "program" && s.sectionKey === homeKey ? "on" : ""}">${esc(s.label)}</button>`
    ).join("")}</div>
    <div id="homeTrendCards">${homeKind !== "program" ? `<div class="empty-row">레시피 불러오는 중…</div>` : recipeCardsHtml([])}</div>
    <div class="phone-body">
      <div style="padding:0 16px 12px">
        <button data-edit-home>이 목록 편집</button>
      </div>
    </div>
  `;
  $("homeStage").querySelectorAll("[data-key]").forEach((btn) => {
    btn.onclick = () => {
      homeKind = btn.dataset.kind;
      homeKey = btn.dataset.key;
      selectedSection = sections.find((s) => s.sectionKey === homeKey) || selectedSection;
      renderHomeStage();
      renderSectionLite();
    };
  });
  const edit = $("homeStage").querySelector("[data-edit-home]");
  if (edit) {
    edit.onclick = () => openCuration(homeKey, current?.label || homeKey);
  }
  const target = homeKind === "program" ? $("homeProgramCards") : $("homeTrendCards");
  const other = homeKind === "program" ? $("homeTrendCards") : $("homeProgramCards");
  if (other) other.innerHTML = `<div class="empty-row">칩을 누르면 이 칸에 레시피가 채워집니다</div>`;
  if (homeKey) {
    loadPreview(homeKey).then((data) => {
      if (target) target.innerHTML = recipeCardsHtml(data.recipes);
    }).catch((e) => toast(String(e.message || e), false));
  }
  renderSectionLite();
}

function renderSectionLite() {
  const s = selectedSection || sections.find((x) => x.sectionKey === homeKey);
  if (!s) {
    $("sectionLiteEdit").innerHTML = `<div class="muted">미리보기에서 카테고리를 고르세요</div>`;
    return;
  }
  $("sectionLiteEdit").innerHTML = `
    <b>${esc(s.label)}</b>
    <div class="muted">${s.kind === "program" ? "TV 프로그램" : s.kind === "moment" ? "모먼트" : "홈 카테고리"}</div>
    <label>화면에 보이는 이름</label>
    <input id="s_label" value="${esc(s.label || "")}" />
    <label>노출</label>
    <select id="s_enabled">
      <option value="true" ${s.enabled !== false ? "selected" : ""}>보이기</option>
      <option value="false" ${s.enabled === false ? "selected" : ""}>숨기기</option>
    </select>
    <div class="actions">
      <button id="s_save">이름 저장</button>
      <button class="ghost" id="s_curate">이 목록 편집</button>
      <button class="danger" id="s_del">숨기기</button>
    </div>
    <div class="muted" style="margin-top:8px">레시피를 넣고 빼는 일은 큐레이션 탭에서 합니다. 새 카테고리 추가는 Cursor로 하는 편이 안전합니다.</div>
  `;
  $("s_save").onclick = saveSectionLite;
  $("s_curate").onclick = () => openCuration(s.sectionKey, s.label);
  $("s_del").onclick = deleteSection;
}

async function saveSectionLite() {
  const s = selectedSection;
  if (!s?.sectionKey) return;
  try {
    const payload = {
      ...s,
      label: $("s_label").value,
      enabled: $("s_enabled").value === "true",
    };
    const data = await api(`/api/sections/${s.sectionKey}`, {
      method: "PUT",
      body: JSON.stringify(payload),
    });
    toast("카테고리 이름 저장됨 · 디버그 앱을 다시 열면 반영됩니다");
    selectedSection = data.section;
    previewCache.clear();
    await loadAll();
  } catch (e) {
    toast(String(e.message || e), false);
  }
}

async function deleteSection() {
  if (!selectedSection?.sectionKey) return;
  if (!confirm("이 카테고리를 숨길까요?")) return;
  try {
    await api(`/api/sections/${selectedSection.sectionKey}`, { method: "DELETE" });
    toast("숨겼습니다");
    selectedSection = null;
    previewCache.clear();
    await loadAll();
  } catch (e) {
    toast(String(e.message || e), false);
  }
}

async function loadIndex() {
  const key = $("curationKey").value;
  if (!key) return;
  try {
    const data = await api(`/api/indexes/${encodeURIComponent(key)}`);
    const titles = data.titles || {};
    const thumbs = data.thumbnails || {};
    const pinned = new Set((data.overrides || {}).pinnedIds || []);
    const blocked = (data.overrides || {}).blockedIds || [];
    $("indexList").innerHTML =
      `<div class="muted">${data.count}개 · 고정 ${pinned.size} · 제외 ${blocked.length}</div>` +
      (data.recipeIds || []).map((id) => `
        <div class="curation-item">
          ${thumbs[id] ? `<img src="${esc(thumbs[id])}" alt="" />` : `<div class="mini"></div>`}
          <div class="grow">
            <b>${esc(titles[id] || id)}</b>
            <div class="muted">${esc(id)}${pinned.has(id) ? " · 맨 위 고정" : ""}</div>
          </div>
          <button class="danger" data-del="${esc(id)}">제거</button>
        </div>`).join("") +
      (blocked.length
        ? `<h4>제외된 레시피</h4>` + blocked.map((id) =>
          `<div class="curation-item"><div class="grow muted">${esc(id)}</div>
           <button class="ghost" data-unb="${esc(id)}">제외 해제</button></div>`
        ).join("")
        : "");
    $("indexList").querySelectorAll("[data-del]").forEach((btn) => {
      btn.onclick = async () => {
        await api(`/api/indexes/${encodeURIComponent(key)}/remove`, {
          method: "POST",
          body: JSON.stringify({ recipeId: btn.dataset.del }),
        });
        toast("제거됨");
        previewCache.delete(key);
        loadIndex();
      };
    });
    $("indexList").querySelectorAll("[data-unb]").forEach((btn) => {
      btn.onclick = async () => {
        await api(`/api/indexes/${encodeURIComponent(key)}/unblock`, {
          method: "POST",
          body: JSON.stringify({ recipeId: btn.dataset.unb }),
        });
        toast("제외 해제");
        previewCache.delete(key);
        loadIndex();
      };
    });
  } catch (e) {
    toast(String(e.message || e), false);
  }
}

async function searchAdd() {
  const q = $("recipeQuery").value.trim();
  const key = $("curationKey").value;
  if (!q || !key) return;
  try {
    const data = await api(
      `/api/recipes/search?q=${encodeURIComponent(q)}&section_key=${encodeURIComponent(key)}`
    );
    const hits = data.recipes || [];
    $("searchHits").innerHTML = hits.map((r) =>
      `<div class="curation-item">
        ${r.thumbnailUrl ? `<img src="${esc(r.thumbnailUrl)}" alt="" />` : `<div class="mini"></div>`}
        <div class="grow"><b>${esc(r.title)}</b><div class="muted">${esc(r.id)}</div></div>
        <button data-add="${esc(r.id)}">추가</button>
      </div>`
    ).join("") || `<div class="muted">없음</div>`;
    $("searchHits").querySelectorAll("[data-add]").forEach((btn) => {
      btn.onclick = async () => {
        await api(`/api/indexes/${encodeURIComponent(key)}/add`, {
          method: "POST",
          body: JSON.stringify({ recipeId: btn.dataset.add }),
        });
        toast("추가됨");
        previewCache.delete(key);
        loadIndex();
      };
    });
  } catch (e) {
    toast(String(e.message || e), false);
  }
}

$("btnLoadIndex").onclick = loadIndex;
$("btnSearch").onclick = searchAdd;
$("btnRebuild").onclick = async () => {
  const key = $("curationKey").value;
  if (!key) return;
  if (!confirm("이 목록을 규칙 기준으로 다시 채울까요? 읽기 비용이 큽니다.")) return;
  try {
    const data = await api(`/api/indexes/${encodeURIComponent(key)}/rebuild`, {
      method: "POST",
      body: JSON.stringify({ confirm: true }),
    });
    toast(`재빌드 ${data.count}개`);
    previewCache.delete(key);
    loadIndex();
  } catch (e) {
    toast(String(e.message || e), false);
  }
};

$("btnRollback").onclick = async () => {
  if (!confirm("직전 CMS 번들로 롤백할까요?")) return;
  try {
    await api("/api/rollback", { method: "POST", body: "{}" });
    toast("롤백됨");
    previewCache.clear();
    await loadAll();
  } catch (e) {
    toast(String(e.message || e), false);
  }
};

async function loadAll() {
  const results = await Promise.allSettled([
    api("/api/posters"),
    api("/api/sections"),
    api("/api/bundle"),
  ]);
  const failed = results.filter((r) => r.status === "rejected");
  if (failed.length) {
    toast(String(failed[0].reason?.message || failed[0].reason), false);
  }
  const p = results[0].status === "fulfilled" ? results[0].value : { posters: [] };
  const s = results[1].status === "fulfilled" ? results[1].value : { sections: [] };
  const b = results[2].status === "fulfilled" ? results[2].value : { bundle: null };
  posters = p.posters || [];
  sections = s.sections || [];
  const updated = b.bundle && b.bundle.updatedAt;
  $("metaLine").textContent = updated
    ? `마지막 저장 ${updated} · 미리보기는 지금 앱에 그려지는 모습입니다`
    : "번들이 없습니다. python migrate_seed.py --write 를 먼저 실행하세요.";
  fillCurationKeys();
  if (!selectedPoster && enabledPosters()[0]) selectedPoster = enabledPosters()[0];
  if (!selectedSection && programSections()[0]) selectedSection = programSections()[0];
  renderPosterPicker();
  renderPosterLite();
  renderPosterStage();
  renderHomeStage();
}

loadAll().catch((e) => toast(String(e.message || e), false));
