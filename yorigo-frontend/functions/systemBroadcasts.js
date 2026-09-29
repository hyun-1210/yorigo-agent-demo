"use strict";

/** @type {Record<string, { campaignId: string, type: string, title: string, body: string }>} */
const SYSTEM_BROADCASTS = {
  instagram_maintenance_2026_06: {
    campaignId: "instagram_maintenance_2026_06",
    type: "system_announcement",
    title: "인스타그램 링크 분석 점검 알림",
    body:
      "서버 점검으로 인해 인스타그램 링크 분석이 일시적으로 불안정할 수 있습니다. 1-2일 내 복구 예정이오니 불편하시더라도 조금만 기다려 주시면 감사하겠습니다. 유튜브, 틱톡은 정상적으로 이용하실 수 있습니다!",
  },
  app_reinstall_2026_07: {
    campaignId: "app_reinstall_2026_07",
    type: "system_announcement",
    title: "요리고 앱 이용 안내",
    body:
      "앱이 열리지 않으면 삭제 후 스토어에서 다시 설치해 주세요. 최신 버전에서 안정성이 개선되었습니다.",
  },
  service_notice_2026_07_21: {
    campaignId: "service_notice_2026_07_21",
    type: "system_announcement",
    title: "📢 서비스 이용 안내",
    body:
      "현재 일시적인 서버 문제로 인해 레시피 분석 및 장바구니 기능이 원활하지 않을 수 있습니다. 현재 빠르게 정상화 작업을 진행 중입니다.\n이용에 불편을 드려 죄송하며, 안정적인 요리GO 앱을 이용하실 수 있도록 최선을 다하겠습니다. 감사합니다.🙏",
  },
};

/**
 * @param {string} campaignId
 * @returns {{ campaignId: string, type: string, title: string, body: string } | null}
 */
function getSystemBroadcast(campaignId) {
  const id = String(campaignId || "").trim();
  if (!id) return null;
  return SYSTEM_BROADCASTS[id] || null;
}

/** @returns {string[]} */
function listSystemBroadcastCampaignIds() {
  return Object.keys(SYSTEM_BROADCASTS);
}

module.exports = {
  SYSTEM_BROADCASTS,
  getSystemBroadcast,
  listSystemBroadcastCampaignIds,
};
