// ════════════════════════════════════════════════════════════════════
//  草稿轉正式案件：Drive 資料夾改名（一案一資料夾）
//  狀態：✅ 已於 2026-08-19 用 clasp 推上線並部署（254 版，部署 ID …Q9cA）
//  這是「線上 Apps Script / 程式碼.gs」的本地鏡像片段，不是完整檔案。
//
//  問題：submitCase() 的草稿轉送出分支原本呼叫 createCaseFolder(newCaseId)，
//        無條件在根目錄「新建」一個以新單號命名的資料夾。但草稿階段上傳的附件
//        早就放在「DRAFT-…」資料夾裡了 → 新的「EWC-…」資料夾從一出生就是空的，
//        憑證留在 DRAFT 資料夾；而送出後再補上傳的附件會進 EWC 資料夾，
//        同一個案件的憑證因此散在兩個資料夾，稽核很難找。
//        （實例：EWC-260818-002 的資料夾是空的——不是檔案被刪，是本來就沒裝過東西。）
//
//  作法：改成把草稿的資料夾「改名」為新單號，一個案件從頭到尾只有一個資料夾。
// ════════════════════════════════════════════════════════════════════

// ── ① submitCase() 草稿轉送出分支：原本這一行 ──
//     createCaseFolder(newCaseId);
//     改成 ↓
//     renameCaseFolder(data.caseId, newCaseId);

// ── ② createCaseFolder() 整支改寫為 renameCaseFolder()（原本只有上面那一個呼叫點）──

// 草稿轉正式時，把草稿的附件資料夾改名成新單號，讓一個案件從頭到尾只有一個資料夾。
// ・找不到舊資料夾就什麼都不做 —— 草稿沒上傳過附件本來就沒有資料夾，不需要先建一個空的
//   （之後真的要上傳時，uploadFileToCase 會自己用新單號建）。
// ・整段包 try/catch：Drive 是這支流程裡最慢也最容易失敗的部分，
//   改名失敗只是歸檔不整齊，絕不能讓已經寫好的送出流程掛掉。
function renameCaseFolder(oldName, newName) {
  if (!oldName || !newName || String(oldName) === String(newName)) return;
  try {
    const root = DriveApp.getFolderById(CONFIG.DRIVE_FOLDER_ID);
    const it   = root.getFoldersByName(String(oldName));
    if (!it.hasNext()) return;
    it.next().setName(String(newName));
  } catch (e) {
    Logger.log('資料夾改名失敗（' + oldName + ' → ' + newName + '）：' + e.message);
  }
}

// ── 還原方式 ──
// 線上部署 …Q9cA 原本釘在 253 版，本次改為 254 版。
// 要退回：clasp deploy -i AKfycbxqmXRfqubdjDRpYQhBOomC9BUM9_US7Wugal-UJ_CbpNp1MbLKq4YocjVRdGuWQ9cA -V 253
