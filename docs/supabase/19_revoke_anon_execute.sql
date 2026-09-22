-- ============================================================
-- 資安 — Migration 19：收回所有 public schema 函式的匿名執行權
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 問題（2026-09-22 對線上資料庫實測，非推測）：
--   select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute');
--   → 15 支函式匿名可執行。
--
-- 根因：Postgres 對新建函式預設 `grant execute to public`，而 `grant ... to authenticated`
--   不會移除那個預設權限。docs/supabase/07~13、15~18 都有明確寫 revoke，
--   但 02_votes.sql（投票）與 03_sheet_sessions.sql 整批漏了。
--
-- 實際影響（依嚴重度）：
--   1. ht_vote_items_get(text)  — SECURITY DEFINER 且函式內零權限檢查
--      → 未登入者可讀任一場次的投票品項清單與 known 全品項快照（店家／品名屬內部資料）。
--   2. _ht_vote_key(p_email, p_event_id) — SECURITY DEFINER
--      → 未登入者可算出「任一同事在任一場次的投票雜湊」。
--        02_votes.sql 檔頭宣稱「連雜湊都拿不到 → 比試算表更難反查」，這個前提目前不成立：
--        vote_key 一旦因為新增 select policy 或報表外流一次，去匿名化就是零成本。
--   3. _ht_is_admin() / _ht_event_date() / _ht_jwt_email() / _ht_today_tw()
--      → 內部 helper 不該對外可呼叫；_ht_event_date 可匿名查任一 event_id 的活動日期。
--   4. ht_vote_submit / ht_vote_close / ht_vote_items_save / ht_sheet_sessions_sync
--      → 函式內部有 v_email='' 或 _ht_is_admin() 擋著，目前無實害，但不該可呼叫。
--
-- 做法：一次掃過所有 public 函式收回 public/anon 的執行權，不動 authenticated
--   （避免誤收正常使用的 RPC）。唯一例外是底線開頭的內部 helper，
--   那些只被 SECURITY DEFINER 函式內部 perform／select 呼叫，
--   而 definer 函式呼叫 definer 函式不需要 caller 具備 execute 權限，
--   所以連 authenticated 一起收回不會破壞任何既有呼叫鏈。
--   （此模式先前已對 massage 的 _ms_% 函式套用過並驗證無誤。）
-- ============================================================

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (has_function_privilege('anon',   p.oid, 'execute')
         or has_function_privilege('public', p.oid, 'execute'))
  loop
    execute format('revoke execute on function %s from public', r.sig);
    execute format('revoke execute on function %s from anon',   r.sig);
    if left(r.proname, 1) = '_' then
      execute format('revoke execute on function %s from authenticated', r.sig);
    end if;
  end loop;
end $$;

-- ─────────────────────────────────────────────
-- 驗證（跑完應為 0）
-- ─────────────────────────────────────────────
select count(*) as anon_can_exec_after
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');

-- 收完後請務必回頭確認「正常功能沒被收壞」：以真實登入身分各跑一次
--   htVoteGet / htVoteItemsGet / htVoteSubmit（活動當天）／massageGetData，
-- 確認回傳仍為 ok。若某支被誤收，補回：
--   grant execute on function <簽名> to authenticated;
