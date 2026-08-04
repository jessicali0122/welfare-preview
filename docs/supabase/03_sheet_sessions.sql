-- ============================================================
-- 舊試算表歷史場次搬家 Migration 03
-- 在 Supabase → SQL Editor 貼上整段執行即可（可重複執行）
-- ------------------------------------------------------------
-- 背景：`htSheetList` 讀的是另一份舊 Google 試算表（每月一個分頁，民國年月命名），
--       用一套 heuristic 去猜「品名／廠商／單價／數量／小計」在第幾欄。那份試算表
--       已經是唯讀的歷史資料（午茶現在跑在 Supabase，不會再新增分頁）。
--
-- 作法：**不重寫那套解析器**（重寫等於重新製造 bug）。改為呼叫一次 GAS 拿到
--       解析好的結果，把每一場整包 JSON 快照進來，之後前端直接讀這張表。
--       回傳格式與 GAS 完全相同 → 前端渲染邏輯一行都不用改。
--
-- 之後若真的需要重新同步（例如有人又去改了舊試算表），重跑一次搬移即可，
-- 不是自動的——這是刻意的，避免唯讀歷史資料被意外覆蓋。
-- ============================================================

create table if not exists ht_sheet_sessions (
  sheet_name text primary key,          -- 舊試算表的分頁名稱（例如 11408）
  ym         text,                       -- yyyy-MM，排序用
  gid        bigint,                     -- 原分頁 gid（前端「開啟原始試算表」用）
  data       jsonb not null,             -- GAS htSheetList 回傳的該場次完整物件（原封不動）
  synced_at  timestamptz default now()
);
create index if not exists idx_ht_sheet_sessions_ym on ht_sheet_sessions(ym desc);

-- ---------- RLS：已登入者唯讀；寫入只在搬移時由 SQL Editor（postgres 角色）進行 ----------
alter table ht_sheet_sessions enable row level security;
drop policy if exists p_ht_sheet_sessions_read on ht_sheet_sessions;
create policy p_ht_sheet_sessions_read on ht_sheet_sessions for select to authenticated using (true);
