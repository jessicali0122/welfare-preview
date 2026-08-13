-- ============================================================
-- 公佈欄搬家：ht_bulletins
-- ------------------------------------------------------------
-- 這支可以重複執行（idempotent）。
--
-- 資料形狀完全對齊現行前端物件：
--   { id, scope, title, content, pinned, author, createdAt }
-- scope: 'home'（首頁）/ 'hightea'（午茶日）/ 'massage'（按摩預約）
--        舊資料沒有 scope 欄位，前端一律視為首頁公告 → 預設 'home'
-- ============================================================

create table if not exists public.ht_bulletins (
  id          text primary key,
  scope       text        not null default 'home',
  title       text        not null,
  content     text        not null default '',
  pinned      boolean     not null default false,
  author      text        not null default '',
  created_at  timestamptz not null default now()
);

-- 首頁／午茶／按摩三個公告欄各自撈自己的 scope，且都按「置頂優先、再依時間倒序」
create index if not exists ht_bulletins_scope_idx
  on public.ht_bulletins (scope, pinned desc, created_at desc);

-- ============================================================
-- RLS
-- ------------------------------------------------------------
-- 與午茶三張表的差別：公告是「全員都要看得到」的東西，所以
--   讀取 → 任何 authenticated（＝拿得到 GAS 簽的 JWT ＝公司帳號登入過）
--   寫入／刪除 → 只有 app_roles 帶 welfare 或 manager
-- anon（只帶 publishable key）一律擋掉，讀 0 筆、寫 401。
--
-- ⚠️ 沿用 rls-role-aware.sql 的教訓：先清掉這張表上所有既有 policy 再建，
--    否則多條 permissive policy 會以 OR 疊加，寬鬆的那條會蓋過角色把關。
-- ============================================================
alter table public.ht_bulletins enable row level security;

do $$
declare pol record;
begin
  for pol in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'ht_bulletins'
  loop
    execute format('drop policy if exists %I on public.ht_bulletins', pol.policyname);
  end loop;
end $$;

-- 讀：登入過的公司帳號都可以
create policy ht_bulletins_read on public.ht_bulletins
  for select to authenticated
  using ( true );

-- 寫／改／刪：限福委或管理者
create policy ht_bulletins_write on public.ht_bulletins
  for insert to authenticated
  with check ( (auth.jwt() -> 'app_roles') ? 'welfare' or (auth.jwt() -> 'app_roles') ? 'manager' );

create policy ht_bulletins_update on public.ht_bulletins
  for update to authenticated
  using      ( (auth.jwt() -> 'app_roles') ? 'welfare' or (auth.jwt() -> 'app_roles') ? 'manager' )
  with check ( (auth.jwt() -> 'app_roles') ? 'welfare' or (auth.jwt() -> 'app_roles') ? 'manager' );

create policy ht_bulletins_delete on public.ht_bulletins
  for delete to authenticated
  using ( (auth.jwt() -> 'app_roles') ? 'welfare' or (auth.jwt() -> 'app_roles') ? 'manager' );

-- ============================================================
-- 舊資料搬家用 RPC
-- ------------------------------------------------------------
-- 沿用 ht_sheet_sessions_sync 的做法：不在 SQL 裡重寫解析邏輯，
-- 由前端呼叫一次 GAS 的 bulletinList 拿到現有公告，整包丟進來 upsert。
-- 限福委／管理者才能執行；可重複執行（同 id 覆蓋）。
-- ============================================================
create or replace function public.ht_bulletins_sync(payload jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer := 0;
begin
  if not ( (auth.jwt() -> 'app_roles') ? 'welfare'
        or (auth.jwt() -> 'app_roles') ? 'manager' ) then
    raise exception '沒有權限執行公告搬移';
  end if;

  insert into public.ht_bulletins (id, scope, title, content, pinned, author, created_at)
  select
    coalesce(nullif(r->>'id', ''), 'B' || md5(r::text)),
    coalesce(nullif(r->>'scope', ''), 'home'),
    coalesce(r->>'title', ''),
    coalesce(r->>'content', ''),
    coalesce((r->>'pinned')::boolean, false),
    coalesce(r->>'author', ''),
    coalesce((r->>'createdAt')::timestamptz, now())
  from jsonb_array_elements(payload) as r
  on conflict (id) do update set
    scope      = excluded.scope,
    title      = excluded.title,
    content    = excluded.content,
    pinned     = excluded.pinned,
    author     = excluded.author,
    created_at = excluded.created_at;

  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.ht_bulletins_sync(jsonb) from public, anon;
grant execute on function public.ht_bulletins_sync(jsonb) to authenticated;
