"use strict";

/**
 * Firebase Cloud Functions에서 사용하는 Mixpanel HTTP Tracking API 래퍼.
 *
 * backend/services/mixpanel_service.py 와 동일한 엔드포인트/페이로드 형식을 사용해서
 * 백엔드(Python)와 Cloud Functions(Node) 이벤트가 같은 Mixpanel 프로젝트에서
 * 일관되게 집계되도록 한다.
 *
 * Env vars:
 *   - MIXPANEL_PROJECT_TOKEN (미설정 시 이벤트 전송을 조용히 스킵)
 */

const _TRACK_URL = "https://api.mixpanel.com/track";
const _TIMEOUT_MS = 5000;

function _getToken() {
  return (process.env.MIXPANEL_PROJECT_TOKEN || "").trim();
}

/**
 * Mixpanel 이벤트를 fire-and-forget 방식으로 전송한다.
 * 네트워크 실패/토큰 미설정 등 어떤 이유로든 예외를 던지지 않으며,
 * 호출한 함수의 주 로직(트리거 처리)에 영향을 주지 않는다.
 *
 * @param {string} distinctId 사용자 uid 또는 시스템 식별자
 * @param {string} event 이벤트 이름
 * @param {Record<string, any>} [properties]
 */
async function trackMixpanelEvent(distinctId, event, properties = {}) {
  const token = _getToken();
  if (!token) return;

  const payload = {
    event,
    properties: {
      token,
      distinct_id: distinctId || "unknown",
      time: Math.floor(Date.now() / 1000),
      ...properties,
    },
  };

  const encoded = Buffer.from(JSON.stringify([payload])).toString("base64");
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), _TIMEOUT_MS);
  try {
    const resp = await fetch(_TRACK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: `data=${encodeURIComponent(encoded)}`,
      signal: ctrl.signal,
    });
    const text = await resp.text();
    if (!resp.ok || text.trim() !== "1") {
      console.warn(
        "[Mixpanel] track failed:",
        resp.status,
        text.slice(0, 200),
        "event=",
        event
      );
    }
  } catch (e) {
    console.warn(
      "[Mixpanel] track error:",
      e && e.message ? e.message : e,
      "event=",
      event
    );
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { trackMixpanelEvent };
