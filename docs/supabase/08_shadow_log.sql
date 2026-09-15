-- ============================================================
-- 案件搬遷 Stage 2 · 影子比對紀錄表（Migration 08）
-- 用途：前端 _shadowCompareCases() 在「舊路 GAS vs 新路 Supabase」有差異時，
--       把報告寫進來，供切換前集中檢視各角色（福委/員工/代理人）是否都一致。
--       只有管理者讀得到；一般使用者只能 insert 自己那筆（透過 log_shadow）。
-- 可重複執行（idempotent）。
-- ============================================================
create table if not exists shadow_log (
  id     bigint generated always as identity primary key,
  email  text,
  at     timestamptz default now(),
  report jsonb
);
alter table shadow_log enable row level security;
drop policy if exists p_shadow_read on shadow_log;
-- 只有管理者能讀（避免一般人看到別人的比對資料）
create policy p_shadow_read on shadow_log for select to authenticated
  using ((auth.jwt() -> 'app_roles') ? 'manager');

-- 寫入用 SECURITY DEFINER RPC，email 取自 JWT（使用者無法偽造成別人）
create or replace function log_shadow(p_report jsonb) returns void
  language sql security definer set search_path = public, extensions as $$
  insert into shadow_log(email, report)
  values (lower(coalesce(auth.jwt() ->> 'email', '')), p_report);
$$;
revoke execute on function log_shadow(jsonb) from public;
revoke execute on function log_shadow(jsonb) from anon;
grant  execute on function log_shadow(jsonb) to   authenticated;

-- 檢視（管理者跑）：最近的差異紀錄
--   select email, at, report from shadow_log order by at desc limit 50;
