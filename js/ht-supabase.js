/* ============================================================
 * 午茶模組 · Supabase 對接層（階段 2）
 * ------------------------------------------------------------
 * 設計原則：
 *  1. 回傳格式與現行 GAS 端「1:1 相同」，前端 UI／渲染完全不用改。
 *  2. 免額外函式庫，直接打 PostgREST REST（Realtime 於階段 3 再加 supabase-js）。
 *  3. 由 index.html 的 htApi() 在最上層以 HT_USE_SUPABASE 開關路由；
 *     開關關閉時完全走原本的 GAS，線上不受影響。
 *
 * 掛載後對外只暴露一個入口：window.htSupabase(action, payload) → Promise<結果物件>
 * ============================================================ */
(function () {
  'use strict';

  // ── 連線設定（publishable key 可安全放前端，靠 RLS 保護）──
  var SB_URL = 'https://miyxennmcyeqfuvfravg.supabase.co';
  var SB_KEY = 'sb_publishable_J5grYqosgbJrTdFEzjNddA_7CddUasH';
  var REST   = SB_URL + '/rest/v1/';

  // 使用者 JWT：登入後由 GAS 用 Supabase JWT secret 簽發（role=authenticated），
  // 存於 window.HT_SB_TOKEN。RLS 只認這張 token；沒有它 → anon → 一律被擋（機密資料不外流）。
  // ★ Fail-closed：沒有有效 JWT 就「不要」退回公開 key。
  //   退回 anon 的話每個請求都會被 RLS 擋成 401，但前端看起來只是「存檔失敗」，
  //   使用者會以為存好了 → 這正是「編輯的東西突然全部消失」的成因。
  function _validToken() {
    var t = (typeof window !== 'undefined' && window.HT_SB_TOKEN) || '';
    return (typeof t === 'string' && t.split('.').length === 3) ? t : '';   // JWT 必須是三段
  }

  function _authToken() { return _validToken() || SB_KEY; }

  function _headers(extra) {
    var h = {
      'apikey': SB_KEY,                          // 專案識別（公開）
      'Authorization': 'Bearer ' + _authToken(), // 身分憑證（GAS 簽的 JWT；未登入則為公開 key → 被 RLS 擋）
      'Content-Type': 'application/json'
    };
    if (extra) for (var k in extra) h[k] = extra[k];
    return h;
  }

  // 統一錯誤處理：一律 resolve 成 {ok:false,error} —— 與 GAS 端呼叫慣例一致（呼叫端只看 r.ok）
  function _sb(path, opts) {
    opts = opts || {};
    // 沒有有效 JWT → 一律不送出，直接回明確錯誤（尤其寫入：寧可擋下也不要假裝存好了）
    if (!_validToken()) {
      return Promise.resolve({ __error: '尚未取得存取憑證（登入憑證簽發失敗），請重新整理頁面；若持續發生請通知管理者', __status: 401 });
    }
    return fetch(REST + path, {
      method: opts.method || 'GET',
      headers: _headers(opts.headers),
      body: opts.body ? JSON.stringify(opts.body) : undefined
    }).then(function (res) {
      return res.text().then(function (txt) {
        var data = null; try { data = txt ? JSON.parse(txt) : null; } catch (e) {}
        if (!res.ok) {
          var msg = (data && (data.message || data.hint || data.details)) || ('HTTP ' + res.status);
          return { __error: msg, __status: res.status };
        }
        return { __data: data };
      });
    }).catch(function (err) {
      return { __error: (err && err.message) || '網路連線失敗' };
    });
  }

  // ── 欄位對映：前端 camelCase ↔ DB snake_case ──
  function eventFromDb(r) {
    if (!r) return null;
    return {
      eventId        : String(r.event_id),
      month          : String(r.month || ''),
      date           : r.event_date || '',
      headcount      : Number(r.headcount) || 0,
      budgetPerPerson: Number(r.budget_pp) || 0,
      totalBudget    : Number(r.budget_total) || 0,
      actualExpense  : Number(r.actual_exp) || 0,
      birthdayBudget : Number(r.birthday_exp) || 0,
      status         : String(r.status || '規劃中'),
      birthdays      : Array.isArray(r.birthdays) ? r.birthdays : (function () { try { return JSON.parse(r.birthdays || '[]'); } catch (e) { return []; } })(),
      notes          : String(r.notes || ''),
      claimId        : String(r.reimburse_ref || ''),
      createdBy      : String(r.created_by || ''),
      createdAt      : r.created_at || '',
      completedAt    : r.completed_at || '',
      organizer1     : String(r.organizer1 || ''),
      organizer2     : String(r.organizer2 || '')
    };
  }

  function itemFromDb(r) {
    return {
      itemId    : String(r.item_id),
      eventId   : String(r.event_id),
      name      : String(r.name || ''),
      vendor    : String(r.vendor || ''),
      category  : String(r.category || '其他'),
      unitPrice : Number(r.unit_price) || 0,
      qty       : Number(r.qty) || 0,
      subtotal  : Number(r.subtotal) || 0,
      serving   : String(r.serving || ''),
      assignee  : String(r.assignee || ''),
      ordered   : r.ordered === true,
      orderedAt : r.ordered_at || '',
      notes     : String(r.notes || ''),
      ratingSum : Number(r.rating_sum) || 0,
      ratingCount: Number(r.rating_count) || 0,
      avgRating : Number(r.avg_rating) || 0,
      link      : String(r.link || ''),
      sortOrder : Number(r.sort_order) || 0
    };
  }

  // 前端 item → DB 欄位（subtotal 是 generated column，不送）
  function itemToDb(it, eventId) {
    var row = {
      item_id   : it.itemId || ('ITM-' + _uuid()),
      event_id  : eventId || it.eventId,
      name      : it.name || '',
      vendor    : it.vendor || '',
      category  : it.category || '其他',
      unit_price: Number(it.unitPrice) || 0,
      qty       : Number(it.qty) || 0,
      serving   : it.serving || '',
      assignee  : it.assignee || '',
      ordered   : !!it.ordered,
      ordered_at: it.ordered ? (it.orderedAt || new Date().toISOString()) : null,
      notes     : it.notes || '',
      link      : it.link || '',
      updated_at: new Date().toISOString()
    };
    if (Number(it.sortOrder) > 0) row.sort_order = Number(it.sortOrder);
    return row;
  }

  function _uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8); return v.toString(16);
    });
  }

  function _enc(v) { return encodeURIComponent(v); }

  // ══════════════════════════════════════════════════════════
  // 各 action 實作（回傳格式對齊 GAS）
  // ══════════════════════════════════════════════════════════

  // 列出所有活動（含 itemCount / orderedCount）
  async function htList() {
    var ev = await _sb('ht_events?select=*&order=month.desc');
    if (ev.__error) return { ok: false, error: ev.__error };
    var events = (ev.__data || []).map(eventFromDb);
    // 品項統計：只取 event_id / ordered，client 端聚合
    var it = await _sb('ht_items?select=event_id,ordered');
    var counts = {};
    if (!it.__error) (it.__data || []).forEach(function (r) {
      var k = String(r.event_id);
      counts[k] = counts[k] || { n: 0, o: 0 };
      counts[k].n++; if (r.ordered === true) counts[k].o++;
    });
    events.forEach(function (e) {
      var c = counts[e.eventId] || { n: 0, o: 0 };
      e.itemCount = c.n; e.orderedCount = c.o;
    });
    return { ok: true, events: events };
  }

  // 取得單一活動 + 其品項（依排序）
  async function htGetItems(p) {
    if (!p || !p.eventId) return { ok: false, error: '缺少活動編號' };
    var evId = String(p.eventId);
    // ★ 兩支查詢彼此無關 → 並行送，載入時間砍半（原本是串行等兩趟）
    // ★ 品項一定要有第二排序鍵：舊資料的 sort_order 可能全是 0，只用 sort_order 排
    //   每次回傳順序都可能不同 → 畫面每輪詢一次就重排一次（使用者看到的「跳一下」）
    var both = await Promise.all([
      _sb('ht_events?event_id=eq.' + _enc(evId) + '&select=*&limit=1'),
      _sb('ht_items?event_id=eq.' + _enc(evId) + '&select=*&order=sort_order.asc,item_id.asc')
    ]);
    var evR = both[0], itR = both[1];
    if (evR.__error) return { ok: false, error: evR.__error };
    var event = (evR.__data && evR.__data[0]) ? eventFromDb(evR.__data[0]) : null;
    if (itR.__error) return { ok: false, error: itR.__error };
    var items = (itR.__data || []).map(itemFromDb);
    _backfillSort(evId, items);   // 舊列補上排序值（背景做，絕不阻塞載入）
    return { ok: true, event: event, items: items };
  }

  // 從試算表搬過來的舊列 sort_order 多半是 0（同分 → 排序不穩定）。
  // 首次讀到就依目前呈現順序補上 1..N。
  // ⚠️ 一定要「單一批次 + 不阻塞」：逐列各發一個 PATCH 的話，每列都會觸發回寫
  //    ht_events.actual_exp 的 trigger → 幾十個併發交易搶同一列的鎖 → 載入卡住/逾時。
  // ⛔ 2026-08-03 暫時停用：出現「編輯的東西不見」的回報，在釐清原因前
  //    不讓任何「使用者沒操作卻自動寫 DB」的行為存在。排序穩定性已由
  //    htGetItems 的 item_id.asc 第二排序鍵保證，關掉它不會讓跳列問題復發。
  var _SORT_BACKFILL_ON = false;
  var _sortFixed = {};
  function _backfillSort(evId, items) {
    if (!_SORT_BACKFILL_ON) return;
    if (_sortFixed[evId]) return;
    var need = items.filter(function (it) { return it.itemId && !(Number(it.sortOrder) > 0); });
    _sortFixed[evId] = 1;
    if (!need.length) return;
    var max = 0;
    items.forEach(function (it) { if (Number(it.sortOrder) > max) max = Number(it.sortOrder); });
    var rows = need.map(function (it) {
      max += 1;
      it.sortOrder = max;                    // 同步回傳給前端，避免下一次寫回又被當成新列
      return { item_id: it.itemId, event_id: evId, sort_order: max };
    });
    // 一趟 upsert 全部搞定；失敗就算了，下次載入再補（不影響使用者）
    _sb('ht_items?on_conflict=item_id', {
      method: 'POST', body: rows,
      headers: { 'Prefer': 'resolution=merge-duplicates,return=minimal' }
    }).then(function (r) {
      if (r && r.__error) _sortFixed[evId] = 0;   // 沒補成功 → 下次載入再試
    });
  }

  // 建立新活動（同月份重複則擋）
  async function htCreate(p, user) {
    if (!p || !p.month) return { ok: false, error: '請填寫月份' };
    var dup = await _sb('ht_events?month=eq.' + _enc(p.month) + '&select=event_id&limit=1');
    if (dup.__error) return { ok: false, error: dup.__error };
    if (dup.__data && dup.__data.length) return { ok: false, error: '該月份已有午茶日活動' };
    var eventId = 'HT-' + p.month;
    var row = {
      event_id: eventId,
      month: p.month,
      event_date: p.date || null,
      headcount: Number(p.headcount) || 0,
      budget_pp: Number(p.budgetPerPerson) || 0,
      budget_total: Number(p.totalBudget) || 0,
      actual_exp: 0, birthday_exp: 0,
      status: '規劃中',
      birthdays: p.birthdays || [],
      notes: p.notes || '',
      reimburse_ref: '',
      created_by: (user && user.email) || '',
      organizer1: p.organizer1 || '',
      organizer2: p.organizer2 || ''
    };
    var ins = await _sb('ht_events', { method: 'POST', body: row, headers: { 'Prefer': 'return=minimal' } });
    if (ins.__error) return { ok: false, error: ins.__error };
    return { ok: true, eventId: eventId };
  }

  // 更新活動基本資訊（只送有帶的欄位）
  async function htUpdate(p) {
    if (!p || !p.eventId) return { ok: false, error: '缺少活動編號' };
    var patch = {};
    if (p.date !== undefined) patch.event_date = p.date || null;
    if (p.headcount !== undefined) patch.headcount = Number(p.headcount) || 0;
    if (p.budgetPerPerson !== undefined) patch.budget_pp = Number(p.budgetPerPerson) || 0;
    if (p.totalBudget !== undefined) patch.budget_total = Number(p.totalBudget) || 0;
    if (p.birthdays !== undefined) { patch.birthdays = p.birthdays || []; patch.birthday_exp = (p.birthdays || []).length * 40; }
    if (p.notes !== undefined) patch.notes = p.notes;
    if (p.status !== undefined) patch.status = p.status;
    if (p.organizer1 !== undefined) patch.organizer1 = p.organizer1;
    if (p.organizer2 !== undefined) patch.organizer2 = p.organizer2;
    patch.updated_at = new Date().toISOString();
    var r = await _sb('ht_events?event_id=eq.' + _enc(p.eventId), { method: 'PATCH', body: patch, headers: { 'Prefer': 'return=minimal' } });
    if (r.__error) return { ok: false, error: r.__error };
    return { ok: true };
  }

  // 刪除活動（品項由 FK on delete cascade 自動連刪）
  async function htDeleteEvent(p) {
    if (!p || !p.eventId) return { ok: false, error: '缺少活動編號' };
    // 已完成不可刪（與 GAS 行為一致）
    var chk = await _sb('ht_events?event_id=eq.' + _enc(p.eventId) + '&select=status&limit=1');
    if (chk.__error) return { ok: false, error: chk.__error };
    if (chk.__data && chk.__data[0] && chk.__data[0].status === '已完成') return { ok: false, error: '已完成的活動無法刪除' };
    var r = await _sb('ht_events?event_id=eq.' + _enc(p.eventId), { method: 'DELETE', headers: { 'Prefer': 'return=minimal' } });
    if (r.__error) return { ok: false, error: r.__error };
    return { ok: true };
  }

  // 批次新增/更新品項（前端逐列協作主力）——一次 upsert；廠商訂購次數由 DB trigger 維護
  async function htUpsertItems(p) {
    if (!p || !p.eventId) return { ok: false, error: '缺少活動編號' };
    if (!Array.isArray(p.items)) return { ok: false, error: '缺少品項資料' };
    if (!p.items.length) return { ok: true, results: [] };
    // 取本活動現有品項的排序值：
    //  ① 已存在的列 → 沿用 DB 既有排序（呼叫端沒帶 sortOrder 時也不會被當成新列丟到最後）
    //  ② 真正的新列 → 接在目前最大值後面
    // 只有「有列沒帶排序」時才需要這趟查詢——前端寫回一律會帶 sortOrder，
    // 所以正常存檔完全不會多跑，避免每次存檔都多一個來回（存檔變慢的元凶）。
    var curSort = {}, maxSort = 0;
    var needLookup = p.items.some(function (it) { return !(Number(it.sortOrder) > 0); });
    if (needLookup) {
      var curR = await _sb('ht_items?event_id=eq.' + _enc(p.eventId) + '&select=item_id,sort_order');
      if (!curR.__error) (curR.__data || []).forEach(function (r) {
        var s = Number(r.sort_order) || 0;
        curSort[String(r.item_id)] = s;
        if (s > maxSort) maxSort = s;
      });
    }
    var rows = p.items.map(function (it) {
      var row = itemToDb(it, p.eventId);
      if (!(Number(row.sort_order) > 0)) {
        var known = curSort[String(row.item_id)];
        if (known > 0) row.sort_order = known;              // 既有列：位置原地不動
        else { maxSort += 1; row.sort_order = maxSort; }    // 新列：排到最後
      }
      return row;
    });
    // on_conflict=item_id：有則更新、無則插入
    var r = await _sb('ht_items?on_conflict=item_id', {
      method: 'POST', body: rows,
      headers: { 'Prefer': 'resolution=merge-duplicates,return=representation' }
    });
    if (r.__error) return { ok: false, error: r.__error };
    var results = (r.__data || []).map(function (row) { return { ok: true, itemId: String(row.item_id), sortOrder: Number(row.sort_order) || 0 }; });
    // 依送入順序對齊（PostgREST 回傳順序不保證）
    var byId = {}; results.forEach(function (x) { byId[x.itemId] = x; });
    var ordered = rows.map(function (row) { return byId[row.item_id] || { ok: true, itemId: String(row.item_id), sortOrder: Number(row.sort_order) || 0 }; });
    return { ok: true, results: ordered };
  }

  // 單列新增/更新（逐列協作）
  async function htUpsertItem(p) {
    if (!p || !p.eventId) return { ok: false, error: '缺少活動編號' };
    if (!p.item) return { ok: false, error: '缺少品項資料' };
    var res = await htUpsertItems({ eventId: p.eventId, items: [p.item] });
    if (!res.ok) return res;
    var first = res.results[0] || {};
    return { ok: true, itemId: first.itemId, sortOrder: first.sortOrder || 0 };
  }

  // 刪除單一品項
  async function htDeleteItem(p) {
    if (!p || !p.itemId) return { ok: false, error: '缺少品項編號' };
    var r = await _sb('ht_items?item_id=eq.' + _enc(p.itemId), { method: 'DELETE', headers: { 'Prefer': 'return=minimal' } });
    if (r.__error) return { ok: false, error: r.__error };
    return { ok: true };
  }

  // 只改排序（拖曳換位）——逐列只更新 sort_order，不動其他欄位
  async function htReorderItems(p) {
    if (!p || !p.eventId) return { ok: false, error: '缺少活動編號' };
    if (!Array.isArray(p.order)) return { ok: false, error: '缺少排序資料' };
    // p.order 預期為 [{itemId, sortOrder}] 或 [itemId...]（後者用索引當排序）
    var updates = p.order.map(function (o, i) {
      var itemId = (o && o.itemId) ? o.itemId : o;
      var sort = (o && Number(o.sortOrder) > 0) ? Number(o.sortOrder) : (i + 1);
      return _sb('ht_items?item_id=eq.' + _enc(itemId), {
        method: 'PATCH', body: { sort_order: sort, updated_at: new Date().toISOString() },
        headers: { 'Prefer': 'return=minimal' }
      });
    });
    var rs = await Promise.all(updates);
    var bad = rs.find(function (r) { return r.__error; });
    if (bad) return { ok: false, error: bad.__error };
    return { ok: true };
  }

  // 廠商清單
  async function htVendors() {
    var r = await _sb('ht_vendors?select=*&order=total_orders.desc');
    if (r.__error) return { ok: false, error: r.__error };
    var vendors = (r.__data || []).map(function (v) {
      return {
        name: String(v.name), category: String(v.category || ''),
        totalOrders: Number(v.total_orders) || 0,
        ratingSum: Number(v.rating_sum) || 0, ratingCount: Number(v.rating_count) || 0,
        avgRating: Number(v.avg_rating) || 0, lastUsed: String(v.last_used || ''), tags: String(v.tags || '')
      };
    });
    return { ok: true, vendors: vendors };
  }

  // ══════════════════════════════════════════════════════════
  // 投票：一律走 RPC（Postgres 函式），不直接讀寫 ht_votes
  // ----------------------------------------------------------
  // 規則（一人一票／限活動當天／限福委關閉投票／滿意度 1-5）都在資料庫函式裡，
  // 前端只是轉呼叫 —— 這樣把關能力與原本的 GAS 伺服器端相同，不會因為改打
  // PostgREST 就掉到「前端說了算」。ht_votes 沒有任何 RLS 政策，只有函式進得去。
  // ══════════════════════════════════════════════════════════
  function _rpc(fn, args) {
    return _sb('rpc/' + fn, { method: 'POST', body: args || {} }).then(function (r) {
      if (r.__error) return { ok: false, error: r.__error };
      var d = r.__data;
      return (d && typeof d === 'object') ? d : { ok: false, error: '投票服務回應異常' };
    });
  }

  // 2026-08-04：歷史投票已搬完（試算表全部僅 1 筆，HTD-2026-07-19），
  // 五個 action 已掛進 HANDLERS，投票正式跑在 Supabase。
  function htVoteGet(p) {
    if (!p || !p.eventId) return Promise.resolve({ ok: false, error: '缺少活動編號' });
    return _rpc('ht_vote_get', { p_event_id: String(p.eventId) });
  }

  function htVoteSubmit(p) {
    if (!p || !p.eventId) return Promise.resolve({ ok: false, error: '缺少活動編號' });
    return _rpc('ht_vote_submit', {
      p_event_id: String(p.eventId),
      p_sat     : Number(p.sat) || 0,
      p_favs    : Array.isArray(p.favs) ? p.favs : [],
      p_comment : String(p.comment || ''),
      p_kiosk   : !!p.kiosk
    });
  }

  function htVoteClose(p) {
    if (!p || !p.eventId) return Promise.resolve({ ok: false, error: '缺少活動編號' });
    return _rpc('ht_vote_close', { p_event_id: String(p.eventId), p_reopen: !!p.reopen });
  }

  function htVoteItemsGet(p) {
    if (!p || !p.eventId) return Promise.resolve({ ok: false, error: '缺少活動編號' });
    return _rpc('ht_vote_items_get', { p_event_id: String(p.eventId) });
  }

  function htVoteItemsSave(p) {
    if (!p || !p.eventId) return Promise.resolve({ ok: false, error: '缺少活動編號' });
    return _rpc('ht_vote_items_save', {
      p_event_id: String(p.eventId),
      p_items   : Array.isArray(p.items) ? p.items : [],
      p_all     : Array.isArray(p.all) ? p.all : []
    });
  }

  // ══════════════════════════════════════════════════════════
  // 階段 3：Realtime（逐列即時協作）
  // ----------------------------------------------------------
  // 走 supabase-js 的 postgres_changes：ht_items 任一列被別人 INSERT/UPDATE/DELETE，
  // 這裡幾百毫秒內就會收到，不必等輪詢。RLS 同樣套用 → 一定要 setAuth(我們的 JWT)。
  // 設計原則：Realtime 是「加速器」不是「唯一來源」——輪詢永遠留著當安全網，
  //          連不上（公司網路擋 WebSocket 等）就自動退回原本的輪詢節奏，功能不受影響。
  // ══════════════════════════════════════════════════════════
  var SB_JS_CDN = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js';
  var _rtLib = null, _rtClient = null, _rtChannel = null, _rtStatus = 'idle', _rtEventId = '', _rtSubscribing = '';

  function _loadRtLib() {
    if (_rtLib) return _rtLib;
    _rtLib = new Promise(function (resolve, reject) {
      if (window.supabase && window.supabase.createClient) return resolve(window.supabase);
      var s = document.createElement('script');
      s.src = SB_JS_CDN;
      s.async = true;
      s.onload = function () {
        if (window.supabase && window.supabase.createClient) resolve(window.supabase);
        else reject(new Error('supabase-js 載入後找不到 createClient'));
      };
      s.onerror = function () { reject(new Error('supabase-js 載入失敗（CDN 被擋？）')); };
      document.head.appendChild(s);
    }).catch(function (e) { _rtLib = null; throw e; });
    return _rtLib;
  }

  // 診斷用計數器寫在 <html> 的 data 屬性上（DevTools／外部工具都看得到，
  // 排查「訂閱成功但沒收到事件」時不必猜）。錯誤絕不靜默吞掉。
  function _bump(k, v) {
    try {
      document.documentElement.dataset[k] =
        (v !== undefined) ? v : (Number(document.documentElement.dataset[k] || 0) + 1);
    } catch (e) {}
  }

  window.htRealtime = {
    status: function () { return _rtStatus; },

    // token 換新時要同步給 Realtime，否則 WebSocket 會在 JWT 過期時被踢掉
    setAuth: function (token) {
      try { if (_rtClient && token) _rtClient.realtime.setAuth(token); } catch (e) {}
    },

    // handlers: { onUpsert(item), onDelete(itemId), onStatus(status) }
    subscribe: async function (eventId, handlers) {
      handlers = handlers || {};
      var tok = _validToken();
      if (!tok) return false;                       // 沒憑證就別開，等有了再說
      if (_rtChannel && _rtEventId === eventId) return true;   // 同一場活動已訂閱
      // htOpenDetail 可能被連呼叫兩次（深連結＋路由）；載入 CDN 期間會有空窗，
      // 沒有這道鎖就會建出兩條 channel，其中一條變成孤兒
      if (_rtSubscribing === eventId) return true;
      _rtSubscribing = eventId;
      window.htRealtime.unsubscribe();

      var lib;
      try { lib = await _loadRtLib(); }
      catch (e) { _rtSubscribing = ''; _rtStatus = 'unavailable'; if (handlers.onStatus) handlers.onStatus(_rtStatus); return false; }

      try {
        if (!_rtClient) {
          _rtClient = lib.createClient(SB_URL, SB_KEY, {
            auth: { persistSession: false, autoRefreshToken: false },
            realtime: { params: { eventsPerSecond: 10 } }
          });
        }
        _rtClient.realtime.setAuth(tok);            // ★ RLS 也管 Realtime，一定要帶 JWT
        _rtEventId = eventId;

        var onRow = function (payload) {
          _bump('rtRecv');
          try {
            if (payload.eventType === 'DELETE') {
              var oldId = payload.old && payload.old.item_id;
              if (oldId && handlers.onDelete) handlers.onDelete(String(oldId));
              return;
            }
            var row = payload.new;
            if (!row || !row.item_id) return;
            if (handlers.onUpsert) handlers.onUpsert(itemFromDb(row));
            _bump('rtApplied');
          } catch (e) {
            _bump('rtErr', String((e && e.message) || e));
            try { console.error('[BeneFlow] Realtime 套用失敗：', e); } catch (e2) {}
          }
        };

        _rtChannel = _rtClient
          .channel('ht-items-' + eventId)
          .on('postgres_changes',
              { event: '*', schema: 'public', table: 'ht_items', filter: 'event_id=eq.' + eventId },
              onRow)
          .subscribe(function (status, err) {
            _rtStatus = status;                     // SUBSCRIBED / CHANNEL_ERROR / TIMED_OUT / CLOSED
            _bump('rtStatus', status + (err ? (' / ' + err) : ''));
            _bump('rtTopic', 'ht-items-' + eventId);
            if (handlers.onStatus) handlers.onStatus(status);
          });
        _rtSubscribing = '';
        return true;
      } catch (e) {
        _rtSubscribing = '';
        _rtStatus = 'unavailable';
        _bump('rtErr', String((e && e.message) || e));
        if (handlers.onStatus) handlers.onStatus(_rtStatus);
        return false;
      }
    },

    unsubscribe: function () {
      try { if (_rtChannel && _rtClient) _rtClient.removeChannel(_rtChannel); } catch (e) {}
      _rtChannel = null; _rtEventId = ''; _rtStatus = 'idle'; _rtSubscribing = '';
    }
  };

  // ── 路由表 ──
  var HANDLERS = {
    htList: htList,
    htGetItems: htGetItems,
    htCreate: htCreate,
    htUpdate: htUpdate,
    htDeleteEvent: htDeleteEvent,
    htSaveItems: htUpsertItems,   // 舊 htSaveItems 語意＝整批寫回，用 upsert 對應
    htUpsertItems: htUpsertItems,
    htUpsertItem: htUpsertItem,
    htDeleteItem: htDeleteItem,
    htReorderItems: htReorderItems,
    htVendors: htVendors,
    // 投票（走 RPC，規則在資料庫端把關）
    htVoteGet: htVoteGet,
    htVoteSubmit: htVoteSubmit,
    htVoteClose: htVoteClose,
    htVoteItemsGet: htVoteItemsGet,
    htVoteItemsSave: htVoteItemsSave
  };

  // 對外入口。payload 內含 token（本層不驗，交由 RLS/前端 gate；user 由 payload 帶入）
  window.htSupabase = function (action, payload) {
    var fn = HANDLERS[action];
    if (!fn) return Promise.resolve({ ok: false, error: 'Supabase 未支援的 action：' + action });
    var user = (payload && payload._user) || (window.currentUser) || null;
    try {
      return Promise.resolve(fn(payload || {}, user)).catch(function (e) {
        return { ok: false, error: (e && e.message) || 'Supabase 呼叫失敗' };
      });
    } catch (e) {
      return Promise.resolve({ ok: false, error: (e && e.message) || 'Supabase 呼叫失敗' });
    }
  };

  // 供 index.html 判斷哪些 action 該走 Supabase
  window.HT_SUPABASE_ACTIONS = Object.keys(HANDLERS);
})();
