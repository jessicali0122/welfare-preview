/**
 * 午茶日 × 舊 Google 試算表（TSA High Tea Day 騰勢高光午茶日）唯讀串接
 * ────────────────────────────────────────────────────────────
 * ⚠️ 本檔案只有「讀取」，沒有任何 insertSheet / setValue / deleteSheet，
 *    技術上不可能動到原試算表的任何資料。
 *
 * 安裝方式：
 * 1. 把整個檔案貼到福委會 Apps Script 專案（新增檔案 ht-sheet-history.gs）。
 * 2. 在 doPost 的 action 分派處加一行：
 *      if (action === 'htSheetList') return _json(htSheetList());
 *    （放在已驗證 token 的區塊內，比照其他 hightea action 的權限檢查。）
 * 3. 部署 → 管理部署作業 → 編輯 → 版本選「新版本」→ 部署（網址不變）。
 */

var HT_SHEET_ID = '104i4tfBTYHer_VZF10AZTJN4XviT9BinAV-vOSx0ZQo';

/**
 * 列出舊試算表所有午茶日場次（含品項明細），含 5 分鐘快取。
 * 分頁名規則：民國年月 5 碼，例如 11507 = 2026 年 7 月，容忍「11404預算」等尾綴。
 */
function htSheetList() {
  var cache = CacheService.getScriptCache();
  var hit = cache.get('htSheetList_v4');
  if (hit) return JSON.parse(hit);

  var ss = SpreadsheetApp.openById(HT_SHEET_ID);
  var sessions = [];
  ss.getSheets().forEach(function (sh) {
    var name = sh.getName();
    var m = /^(\d{3})(\d{2})/.exec(name);
    if (!m) return; // 略過「廠商一覽表」等非月份分頁
    var year = parseInt(m[1], 10) + 1911;
    var month = parseInt(m[2], 10);
    if (month < 1 || month > 12) return;
    try {
      sessions.push(_htParseSheet(sh, name, year, month));
    } catch (e) {
      // 早期分頁格式不一：解析失敗仍回傳基本資訊，不讓整個列表壞掉
      sessions.push({ sheetName: name, ym: year + '-' + ('0' + month).slice(-2), items: [], parseError: String(e) });
    }
  });
  sessions.sort(function (a, b) { return (b.ym || '').localeCompare(a.ym || ''); });

  var out = { ok: true, sessions: sessions };
  try { cache.put('htSheetList_v4', JSON.stringify(out), 300); } catch (e) {} // 超過 100KB 就不快取
  return out;
}

/** 解析單一月份分頁：標題日期、品項明細、小計、預算。純讀取。 */
function _htParseSheet(sh, name, year, month) {
  var lastRow = Math.min(sh.getLastRow(), 60);
  var lastCol = Math.min(sh.getLastColumn(), 14);
  var vals = sh.getRange(1, 1, lastRow, lastCol).getDisplayValues();

  // 標題列找日期（例：2026/07/20 TSA High Tea Day 規劃）
  var date = '';
  for (var r = 0; r < Math.min(3, vals.length); r++) {
    var line = vals[r].join(' ');
    var dm = /(\d{4})\/(\d{1,2})\/(\d{1,2})/.exec(line);
    if (dm) { date = dm[1] + '/' + ('0' + dm[2]).slice(-2) + '/' + ('0' + dm[3]).slice(-2); break; }
  }

  // 表頭列：找到含「品名」的列，動態對應各欄（不同年份欄位位置略有差異也能解析）
  var headRow = -1, col = {};
  for (var r2 = 0; r2 < Math.min(6, vals.length); r2++) {
    var idx = -1;
    for (var ci = 0; ci < vals[r2].length; ci++) {
      if (String(vals[r2][ci]).replace(/\s/g, '').indexOf('品名') > -1) { idx = ci; break; }
    }
    if (idx > -1) {
      headRow = r2;
      // 模糊比對：各年份分頁表頭寫法略有差異（「負責人員」「訂購」「備註/說明」等）也能對上
      vals[r2].forEach(function (h, c) {
        h = String(h).replace(/\s/g, '');
        if (!h) return;
        if (h.indexOf('品名') > -1 && col.item == null) col.item = c;
        else if (h.indexOf('廠商') > -1 && col.vendor == null) col.vendor = c;
        else if (h.indexOf('單價') > -1 && col.price == null) col.price = c;
        else if (h.indexOf('數量') > -1 && col.qty == null) col.qty = c;
        else if (h.indexOf('小計') > -1 && col.sub == null) col.sub = c;
        else if (h.indexOf('負責') > -1 && col.owner == null) col.owner = c;
        else if (h.indexOf('訂購') > -1 && col.ordered == null) col.ordered = c;
        else if ((h.indexOf('備註') > -1 || h.indexOf('說明') > -1) && col.note == null) col.note = c;
      });
      break;
    }
  }

  // 合併儲存格會讓表頭與資料錯位一至三欄：依實際資料密度自動校正每個欄位
  function _adjCol(c, numeric) {
    if (c == null) return c;
    function score(cc) {
      if (cc == null || cc < 0) return -1;
      var s = 0;
      for (var rr = headRow + 1; rr < Math.min(headRow + 16, vals.length); rr++) {
        var v = String((vals[rr] || [])[cc] == null ? '' : (vals[rr] || [])[cc]).trim();
        if (!v) continue;
        if (numeric) { if (_htNum(v) > 0) s++; }
        else if (!/^\d+(\.\d+)?$/.test(v)) s++;
      }
      return s;
    }
    var best = c, bs = score(c);
    [c + 1, c + 2, c + 3, c - 1].forEach(function (cand) {
      for (var k in col) { if (col[k] === cand) return; }
      var sc = score(cand);
      if (sc > bs) { bs = sc; best = cand; }
    });
    return best;
  }
  col.item = _adjCol(col.item, false);
  col.vendor = _adjCol(col.vendor, false);
  col.price = _adjCol(col.price, true);
  col.qty = _adjCol(col.qty, true);
  col.sub = _adjCol(col.sub, true);
  col.owner = _adjCol(col.owner, false);
  col.ordered = _adjCol(col.ordered, false);
  col.note = _adjCol(col.note, false);

  var items = [], subtotal = 0;
  if (headRow > -1 && col.item != null) {
    for (var r3 = headRow + 1; r3 < vals.length; r3++) {
      var row = vals[r3];
      var itemName = String(row[col.item] || '').trim();
      // 到達預算區或小計列就停止
      if (itemName === '預算名稱' || row.indexOf('預算名稱') > -1) break;
      if (!itemName) continue;
      if (/^\d+(\.\d+)?$/.test(itemName) || itemName === '餐點') continue; // 跳過編號欄與列標籤
      var sub = _htNum(col.sub != null ? row[col.sub] : '');
      subtotal += sub;
      items.push({
        name: itemName,
        vendor: col.vendor != null ? String(row[col.vendor] || '').trim() : '',
        price: _htNum(col.price != null ? row[col.price] : ''),
        qty: _htNum(col.qty != null ? row[col.qty] : ''),
        subtotal: sub,
        owner: col.owner != null ? String(row[col.owner] || '').trim() : '',
        ordered: col.ordered != null ? String(row[col.ordered] || '').trim() : '',
        note: col.note != null ? String(row[col.note] || '').trim() : '',
      });
    }
  }

  // 預算區：找「預算名稱」表頭，抓 人數 與 總預算
  var headcount = 0, budgetTotal = 0;
  for (var r4 = 0; r4 < vals.length; r4++) {
    var bIdx = vals[r4].indexOf('預算名稱');
    if (bIdx === -1) continue;
    var cCnt = vals[r4].indexOf('人數');
    for (var r5 = r4 + 1; r5 < Math.min(r4 + 8, vals.length); r5++) {
      if (cCnt > -1) headcount = Math.max(headcount, _htNum(vals[r5][cCnt]));
      var line2 = vals[r5].join(' ');
      if (line2.indexOf('總預算') > -1) {
        vals[r5].forEach(function (v) { var n = _htNum(v); if (n > budgetTotal) budgetTotal = n; });
      }
    }
    break;
  }

  return {
    sheetName: name,
    ym: year + '-' + ('0' + month).slice(-2),
    date: date,
    title: year + '/' + ('0' + month).slice(-2) + ' 午茶日',
    items: items,
    subtotal: Math.round(subtotal),
    headcount: headcount,
    budgetTotal: budgetTotal,
  };
}

function _htNum(v) {
  var n = parseFloat(String(v == null ? '' : v).replace(/[,\s]/g, ''));
  return isNaN(n) ? 0 : n;
}
