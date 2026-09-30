-- ============================================================
-- 到職日鏡像（2026-09-30）：讓補助試算從 Supabase 秒讀「本人到職日」，不必等 GAS
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 正本仍是 Google 試算表 users!J（到職日）；GAS 每分鐘 syncCasesToSupabase 順帶上拋一次。
-- ★ 刻意「另開一張表」而不是加進 members_mirror：成員表是全員可讀（顯示姓名用），
--   加進去等於每個人都看得到全公司到職日。這張表不開放任何直接讀寫，只能透過：
--     * hire_dates_sync(p_rows)  ── 限管理者（GAS 同步用的管理者 JWT）
--     * get_my_hire_date()       ── 任何登入者，但只回「JWT 本人」那一筆
-- 後端送出補助時仍以 GAS 讀試算表正本重算金額，這張表只影響「畫面上的試算」。
-- ============================================================

create table if not exists member_hire_dates (
  email      text primary key,
  hire_date  date,
  updated_at timestamptz not null default now()
);

alter table member_hire_dates enable row level security;
-- 不建立任何 policy ＝ anon／authenticated 直接查表一律 0 筆；另外把表權限也收掉，雙重保險
revoke all on table member_hire_dates from public, anon, authenticated;

-- 同步：整包覆蓋（payload 沒有的 email 刪掉，例如已刪除的帳號）
create or replace function hire_dates_sync(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  if not _ht_is_admin() then
    raise exception '僅限系統同步呼叫' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows 必須是陣列';
  end if;
  insert into member_hire_dates (email, hire_date, updated_at)
  select lower(trim(r->>'email')),
         case when (r->>'hire_date') ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'hire_date')::date end,
         now()
    from jsonb_array_elements(p_rows) r
   where coalesce(trim(r->>'email'), '') <> ''
  on conflict (email) do update set hire_date = excluded.hire_date, updated_at = now()
   where member_hire_dates.hire_date is distinct from excluded.hire_date;
  delete from member_hire_dates m
   where not exists (select 1 from jsonb_array_elements(p_rows) r where lower(trim(r->>'email')) = m.email);
  select count(*) into n from member_hire_dates;
  return jsonb_build_object('ok', true, 'count', n);
end $$;

-- 讀取：只回 JWT 本人的到職日（看不到別人的）
create or replace function get_my_hire_date()
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'ok', true,
    'hireDate', coalesce((select to_char(hire_date, 'YYYY-MM-DD') from member_hire_dates where email = _ht_jwt_email()), '')
  )
  where _ht_jwt_email() <> ''
$$;

revoke execute on function hire_dates_sync(jsonb) from public, anon;
revoke execute on function get_my_hire_date()     from public, anon;
grant  execute on function hire_dates_sync(jsonb) to authenticated;   -- 函式內再以 _ht_is_admin 擋到只剩管理者
grant  execute on function get_my_hire_date()     to authenticated;

-- ─────────────────────────────────────────────
-- 驗證：anon 全部 false；authenticated 可執行兩支函式、但不能直接讀表
-- ─────────────────────────────────────────────
select has_function_privilege('anon', 'hire_dates_sync(jsonb)', 'execute')          as anon_sync,
       has_function_privilege('anon', 'get_my_hire_date()', 'execute')              as anon_get,
       has_table_privilege('anon', 'member_hire_dates', 'select')                   as anon_table,
       has_table_privilege('authenticated', 'member_hire_dates', 'select')          as auth_table,
       has_function_privilege('authenticated', 'get_my_hire_date()', 'execute')     as auth_get;
