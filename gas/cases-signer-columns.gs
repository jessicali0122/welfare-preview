// ════════════════════════════════════════════════════════════════════
//  cases：每關簽核人姓名欄位（稽核用）
//  狀態：⚠️ 尚未套用到線上 Apps Script（2026-08-18 Chrome 自動化斷線）
//  這是「要貼進 BeneFlow後端 / 程式碼.gs 的片段」的本地鏡像，不是完整檔案。
//
//  背景：cases 每關目前只有「簽N結果 / 簽N時間 / 簽N意見」，沒有簽核人姓名。
//        稽核要看「哪一關、誰簽的、什麼時候簽的」，只能從第 33 欄
//        「簽核鏈快照」的 JSON 回推，很不直覺。
//
//  設計：新欄位一律「接在最後面」（35~38），不可插在中間 —— COLS 是
//        以絕對欄號定義的，中間插欄會讓所有既有常數錯位。
// ════════════════════════════════════════════════════════════════════

// ── ① COLS：加在 PAY_METHOD:34 後面 ──────────────────────────────────
//   SIGN_BY1  :35,   // 第1關簽核人姓名
//   SIGN_BY2  :36,
//   SIGN_BY3  :37,
//   SIGN_BY4  :38,

// ── ② getSheet('cases') 的表頭陣列：在 '簽核鏈快照','付款方式', 後面補 ──
//   '簽1簽核人','簽2簽核人','簽3簽核人','簽4簽核人',

// ── ③ 共用寫入器 ────────────────────────────────────────────────────
// 在 approveCase / rejectCase 寫完「簽N結果 / 簽N時間」之後呼叫一次。
// step 為 1-indexed 的關卡編號，name 為當下操作者姓名
// （取法與 voidCase 一致：getUserInfo(user.email).name || user.name）。
function _writeSignerName_(sh, row, step, name) {
  var n = Number(step);
  if (!(n >= 1 && n <= 4) || !name) return;
  var col = COLS.SIGN_BY1 + (n - 1);
  if (sh.getMaxColumns() < col) sh.insertColumnsAfter(sh.getMaxColumns(), col - sh.getMaxColumns());
  sh.getRange(row, col).setValue(String(name));
}

// 呼叫點（兩處）：
//   approveCase：核准寫入後 → _writeSignerName_(sh, row, step, actorName);
//   rejectCase ：退件寫入後 → _writeSignerName_(sh, row, step, actorName);

// ── ④ 一次性維護：表頭補到 38 欄，並回填既有案件的簽核人 ─────────────
// 回填來源＝第 33 欄「簽核鏈快照」（送出當下的簽核鏈 JSON）。
// 只在「該關有結果、且簽核人欄還空著」時才寫，不覆蓋任何已有資料。
function fixCasesHeaderV2() {
  var sh = getSheet('cases');
  var H = [
    '案件編號','建立時間','申請人email','申請人姓名','部門','主旨',
    '未稅','稅額','含稅','備註','明細','附件','狀態','關卡',
    '簽1結果','簽1時間','簽1意見','簽2結果','簽2時間','簽2意見',
    '簽3結果','簽3時間','簽3意見','簽4結果','簽4時間','簽4意見',
    '收款人','帳號','員工編號','申請日期','退件歷史','重送次數',
    '簽核鏈快照','付款方式',
    '簽1簽核人','簽2簽核人','簽3簽核人','簽4簽核人',
  ];
  if (sh.getMaxColumns() < H.length) sh.insertColumnsAfter(sh.getMaxColumns(), H.length - sh.getMaxColumns());
  sh.getRange(1, 1, 1, H.length).setValues([H]);

  var last = sh.getLastRow();
  if (last < 2) return '表頭已更新（無資料列）';
  var rng  = sh.getRange(2, 1, last - 1, H.length);
  var vals = rng.getValues();
  var filled = 0;
  for (var i = 0; i < vals.length; i++) {
    var r = vals[i];
    var snap = [];
    try { snap = JSON.parse(r[COLS.FLOW_SNAP - 1] || '[]') || []; } catch (e) { snap = []; }
    if (!snap.length) continue;
    for (var st = 1; st <= 4; st++) {
      var resultCol = 15 + (st - 1) * 3;              // 簽N結果（1-indexed）
      var byCol     = COLS.SIGN_BY1 + (st - 1);
      if (!r[resultCol - 1]) continue;                // 這關還沒簽過
      if (r[byCol - 1]) continue;                     // 已有簽核人，不覆蓋
      var p = snap[st - 1];
      var nm = p && (p.name || p.email);
      if (!nm) continue;
      vals[i][byCol - 1] = String(nm);
      filled++;
    }
  }
  rng.setValues(vals);
  return '表頭已更新為 ' + H.length + ' 欄，回填簽核人 ' + filled + ' 格';
}
