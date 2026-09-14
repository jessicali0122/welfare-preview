// ══════════════════════════════════════════════════════════════════
//  bootstrap：登入合併請求（貼進 Apps Script「騰勢福委會_後端」的 程式碼.gs）
//
//  安裝步驟：
//   1. 把下面的 bootstrap() 函式整段貼到 程式碼.gs 最後面
//   2. 在 doPost 的 dispatcher 裡，list 那一行「上面」加一行：
//        if (action === 'bootstrap')   return respond(bootstrap(data, user));
//   3. ★ 部署 → 管理部署作業 → 編輯（鉛筆）→ 版本選「新版本」→ 部署
//      （只 push 程式碼不會生效，一定要重新部署）
// ══════════════════════════════════════════════════════════════════

// ── 登入合併請求（bootstrap）─────────────────────────────────────────
// GAS 對同一位使用者是「排隊」處理的，不會平行跑：前端登入後原本要打 7 支唯讀 API
// （list / getMembers / getFlowInfo / getApplyItems / getAvatar / getSuppliers / logLogin），
// 等於排 7 輪，每輪 1～15 秒 → 登入後畫面一格一格慢慢冒出來。
// 這支把它們併成一次往返；每一項各自 try/catch，單項失敗只讓那一項變 null，
// 前端會退回原本的單支 API 自己補抓，不會整個登入失敗。
function bootstrap(data, user) {
  function safe(fn) { try { return fn(); } catch (e) { Logger.log('bootstrap 子項失敗：' + e.message); return null; } }
  var out = { ok: true };
  out.list         = safe(function(){ return listCases(data, user); });
  out.getMembers   = safe(function(){ return getMembers(data, user); });
  out.getFlowInfo  = safe(function(){ return { ok: true, approvers: getApprovers() }; });
  out.getApplyItems= safe(function(){ return { ok: true, items: getApplyItems() }; });
  out.getAvatar    = safe(function(){ return getAvatar(data, user); });
  out.getSuppliers = safe(function(){ return getSuppliers(data, user); });
  // 管理者才附流程設定（一般人不會進系統管理，不必背這包）
  if (isAdmin(user.email)) out.getFlow = safe(function(){ return getFlow(data, user); });
  // 登入紀錄：純寫入副作用，順道做掉，省一趟
  safe(function(){ return logLogin(data, user); });
  // ★ getAvatars（全體頭像）刻意不併進來：那是好幾 MB 的 base64，
  //   併進來會把這包唯讀資料一起拖慢。維持前端延後單獨抓。
  return out;
}
