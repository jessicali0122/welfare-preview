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

-- ---------- RLS：已登入者唯讀；寫入只能透過下面的同步 RPC（限管理者）----------
alter table ht_sheet_sessions enable row level security;
drop policy if exists p_ht_sheet_sessions_read on ht_sheet_sessions;
create policy p_ht_sheet_sessions_read on ht_sheet_sessions for select to authenticated using (true);

-- ---------- 同步 RPC ----------
-- 從 GAS 的 htSheetList 取回 sessions 陣列後，整包丟進來即可（upsert，可重複執行）。
-- 限管理者（ht_admins），避免任何人都能覆蓋歷史資料。
-- 之後若舊試算表又被修改，重跑一次這支就好，不必進 SQL Editor。
create or replace function ht_sheet_sessions_sync(p_sessions jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0;
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_sessions is null or jsonb_typeof(p_sessions) <> 'array' then
    return jsonb_build_object('ok', false, 'error', '缺少場次資料');
  end if;

  insert into ht_sheet_sessions (sheet_name, ym, gid, data, synced_at)
  select s ->> 'sheetName',
         s ->> 'ym',
         nullif(s ->> 'gid', '')::bigint,
         s,
         now()
    from jsonb_array_elements(p_sessions) as s
   where coalesce(s ->> 'sheetName', '') <> ''
  on conflict (sheet_name) do update
     set ym = excluded.ym, gid = excluded.gid, data = excluded.data, synced_at = now();

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'synced', n,
                            'total', (select count(*) from ht_sheet_sessions));
end $$;

grant execute on function ht_sheet_sessions_sync(jsonb) to authenticated;
