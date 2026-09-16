-- ============================================================
-- 費用申請「單一案件詳情」讀取搬 Supabase — Migration 09（Stage 4：詳情鏡像）
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 目的：把「點開單一案件詳情」callAPI('get') 也改成從 Supabase 讀，繞過 GAS 安全頁 → 秒開。
--
-- 安全設計（與 07 完全同一把尺）：
--   1. case_detail_mirror【直接讀一律擋】(RLS 開、無 select policy)。
--   2. 前端只能透過 get_my_case(p_case_id) 拿資料；函式在 DB 端重現 getCase 的可見規矩：
--        管理者 / 申請人本人 / email 在該案簽核鏈快照(chain_emails) / 生效代理人。
--      → 是 getCase 權限判斷的「子集」，永遠不會多給（資安只會少給、不外洩）。
--   3. 寫入(同步)只能透過 case_detail_sync() RPC，且限管理者(_ht_is_admin())。
--   4. data 就是 GAS getCase() 的完整回傳（原封），前端渲染邏輯完全不用改 → 零走鐘。
--
-- 依賴：07 已建（_ht_is_admin 已存在）、JWT 帶 email/app_roles/proxy_for（sb-token 已簽）。
-- ============================================================

-- ─────────────────────────────────────────────
-- A) 案件詳情鏡像表
-- ─────────────────────────────────────────────
create table if not exists case_detail_mirror (
  case_id         text primary key,               -- 單號（EWC-… / DRAFT-…）
  applicant_email text,                            -- 申請人 email（小寫）— 可見範圍用
  chain_emails    text[] not null default '{}',    -- 該案簽核鏈快照的簽核人 email（小寫）— 可見範圍用
  data            jsonb not null,                  -- getCase() 產出的該案完整物件（原封，含 items/files/approvals…）
  synced_at       timestamptz default now()
);
create index if not exists idx_case_detail_applicant on case_detail_mirror(applicant_email);
create index if not exists idx_case_detail_chain     on case_detail_mirror using gin(chain_emails);

-- RLS：開啟但【不建任何 select policy】→ 直接讀一律擋。
alter table case_detail_mirror enable row level security;
do $$
declare pol record;
begin
  for pol in select policyname from pg_policies
             where schemaname='public' and tablename='case_detail_mirror'
  loop execute format('drop policy if exists %I on public.case_detail_mirror', pol.policyname); end loop;
end $$;

-- ─────────────────────────────────────────────
-- B) 帶授權的單案讀取函式：只在「我有權看這張單」時回它的完整 data，否則回 NULL
--    可見範圍 = 管理者 OR 申請人本人 OR email 在簽核鏈快照 OR 生效代理人（與 get_my_cases 同）
-- ─────────────────────────────────────────────
create or replace function get_my_case(p_case_id text) returns jsonb
  language sql stable security definer set search_path = public, extensions as $$
  select data
    from case_detail_mirror
   where case_id = p_case_id
     and (((auth.jwt() -> 'app_roles') ? 'manager')                                  -- 管理者：全部
      or applicant_email = lower(coalesce(auth.jwt() ->> 'email', ''))               -- 申請人本人
      or lower(coalesce(auth.jwt() ->> 'email', '')) = any(chain_emails)             -- 在簽核鏈上的人
      or chain_emails && (                                                           -- 生效代理人
           select coalesce(array_agg(lower(x)), '{}'::text[])
             from jsonb_array_elements_text(
                    case when jsonb_typeof(auth.jwt() -> 'proxy_for') = 'array'
                         then auth.jwt() -> 'proxy_for' else '[]'::jsonb end) as x))
   limit 1;
$$;
revoke execute on function get_my_case(text) from public;
revoke execute on function get_my_case(text) from anon;
grant  execute on function get_my_case(text) to   authenticated;

-- ─────────────────────────────────────────────
-- C) 同步 RPC：GAS 把「全部案件詳情（未過濾）」整包丟進來 upsert（限管理者）
--    p_details = [{case_id, applicant_email, chain_emails[], data(=getCase 完整回傳)}...]
--    僅 upsert 傳入的列，不刪除舊列（避免暫時抓不到就清空詳情）。
-- ─────────────────────────────────────────────
create or replace function case_detail_sync(p_details jsonb) returns jsonb
  language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0;
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_details is null or jsonb_typeof(p_details) <> 'array' then
    return jsonb_build_object('ok', false, 'error', '缺少詳情資料');
  end if;

  insert into case_detail_mirror (case_id, applicant_email, chain_emails, data, synced_at)
  select d ->> 'case_id',
         lower(coalesce(d ->> 'applicant_email', '')),
         coalesce(
           (select array_agg(lower(x))
              from jsonb_array_elements_text(
                     case when jsonb_typeof(d -> 'chain_emails') = 'array'
                          then d -> 'chain_emails' else '[]'::jsonb end) as x
             where coalesce(x, '') <> ''),
           '{}'
         ),
         d -> 'data',
         now()
    from jsonb_array_elements(p_details) as d
   where coalesce(d ->> 'case_id', '') <> ''
     and jsonb_typeof(d -> 'data') = 'object'
  on conflict (case_id) do update
     set applicant_email = excluded.applicant_email,
         chain_emails    = excluded.chain_emails,
         data            = excluded.data,
         synced_at       = now();

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'synced', n,
                            'total', (select count(*) from case_detail_mirror));
end $$;
revoke execute on function case_detail_sync(jsonb) from public;
revoke execute on function case_detail_sync(jsonb) from anon;
grant  execute on function case_detail_sync(jsonb) to   authenticated;

-- ─────────────────────────────────────────────
-- D) 驗證用（選跑）
-- ─────────────────────────────────────────────
--   select count(*) from case_detail_mirror;          -- 直接讀預期 0（被 RLS 擋）
--   select get_my_case('EWC-260914-0002');            -- 以目前登入者身分測（前端 rpc/get_my_case）
