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


// ════════════════════════════════════════════════════════════════════
//  刪除案件／草稿時，一併把附件資料夾移到 Drive 垃圾桶
//  狀態：✅ 已於 2026-08-19 用 clasp 推上線並部署（255 版）
//
//  背景：deleteDraftCase() 與 deleteCaseByAdmin() 原本只有 sh.deleteRow()，
//        完全不碰 Drive → 案件刪掉了，附件資料夾永遠留在雲端硬碟變孤兒。
//        （相對的好處是不會誤刪：所以刪掉重複草稿 0011 並沒有影響 0010 的檔案。）
// ════════════════════════════════════════════════════════════════════

// ── ① deleteDraftCase()：writeLog 之後、return 之前 ──
//     trashCaseFolder(data.caseId);
// ── ② deleteCaseByAdmin()：sh.deleteRow(i + 1) 之後、return 之前 ──
//     trashCaseFolder(p.caseId);
// ── ③ 新增下列函式（放在 renameCaseFolder 旁邊）──

// 刪除案件／草稿時，一併把該單號的附件資料夾移到 Drive 垃圾桶。
// ・只認「名稱完全等於單號、且直接位於 CONFIG.DRIVE_FOLDER_ID 底下」的資料夾，
//   不會誤刪其他東西；不比對 fileId（同一個檔案可能被別的列引用到）。
// ・用 setTrashed：進垃圾桶保留 30 天可還原，不做永久刪除。
// ・一定要在資料列刪掉「之後」才呼叫。反過來若 Drive 先成功、寫入卻失敗，
//   會變成案件還在、憑證卻不見了。
// ・整段 try/catch：Drive 失敗最多留下一個孤兒資料夾（等同修改前的行為），
//   不該讓刪除流程整個報錯。
function trashCaseFolder(caseId) {
  if (!caseId) return;
  try {
    const root = DriveApp.getFolderById(CONFIG.DRIVE_FOLDER_ID);
    const it   = root.getFoldersByName(String(caseId));
    while (it.hasNext()) it.next().setTrashed(true);   // 同名多個（舊資料）一併處理
  } catch (e) {
    Logger.log('資料夾刪除失敗（' + caseId + '）：' + e.message);
  }
}

// 注意：作廢（voidCase）刻意不刪 —— 作廢保留單號與簽核紀錄供稽核，憑證必須留著。
