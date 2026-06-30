/* ── teaAIService.js ────────────────────────────────────────
 *  AI 午茶助手：前端 → GAS 通訊層
 *  所有對外 API 呼叫集中在此；teaAI.js 只負責 UI，不直接 fetch。
 *
 *  資料流：
 *    GitHub Pages (teaAI.js)
 *      → TeaAIService.plan()
 *        → GAS (action: 'teaAIPlan')
 *          → Google Sheets (config: Gemini API URL / key)
 *            → Gemini API
 *          ← GAS 回傳推薦結果
 *      ← Promise<result>
 *    teaAI.js 渲染結果
 * ─────────────────────────────────────────────────────────── */
(function () {
  'use strict';

  /* ── GAS 端點：沿用主系統同一支 GAS（不另建）── */
  var TEA_AI_GAS_URL = (function () {
    /* 優先讀主系統已定義的 API_URL（index.html 頂層 const），
     * 若因模組載入順序問題取不到，才 fallback 到空字串。
     * 實際 URL 集中管理在 index.html 的 API_URL 常數，此處不重複寫死。 */
    return (typeof API_URL !== 'undefined' && API_URL) || '';
  })();

  /* ── 取得目前登入者 token（跨模組取用）── */
  function _getToken() {
    var u = (typeof currentUser !== 'undefined' && currentUser)
          || window.currentUser;
    return (u && u.token) || '';
  }

  /* ── 核心 POST 方法 ── */
  function _post(action, data) {
    if (!TEA_AI_GAS_URL) {
      return Promise.reject(new Error('TEA_AI_GAS_URL 尚未設定'));
    }
    var body = Object.assign({ action: action, token: _getToken() }, data || {});
    return fetch(TEA_AI_GAS_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: JSON.stringify(body),
      redirect: 'follow'
    }).then(function (res) {
      return res.json();
    }).catch(function (err) {
      return { ok: false, error: err.message || '網路錯誤' };
    });
  }

  /* ══════════════════════════════════════════════
   *  公開介面 window.TeaAIService
   * ══════════════════════════════════════════════ */
  window.TeaAIService = {

    /**
     * 請 GAS 呼叫 Gemini 規劃午茶方案
     *
     * @param {object} params
     *   people  {number} 人數
     *   budget  {number} 總預算（元）
     *   types   {string[]} 餐點類型，例如 ['飲料','甜點']
     *   special {string}  特殊需求自由文字
     *
     * @returns {Promise<{ok:boolean, plans:Array, tip:string, source:string, error?:string}>}
     *   plans[]  每個方案：{ name, desc, items[], cost }
     *   tip      給福委的建議文字
     *   source   'gemini' | 'mock'（GAS 端決定，前端不感知）
     */
    plan: function (params) {
      return _post('teaAIPlan', {
        people:  params.people,
        budget:  params.budget,
        types:   params.types || [],
        special: params.special || ''
      });
    },

    /**
     * 預留：讀取 AI 歷史紀錄
     * @returns {Promise<{ok:boolean, records:Array}>}
     */
    listHistory: function () {
      return _post('teaAIPlanHistory', {});
    }

    /* 未來可擴充：saveResult、rateResult … */
  };

})();
