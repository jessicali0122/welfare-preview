-- ============================================================
-- 費用申請「案件 + 成員」讀取搬 Supabase — Migration 07（Stage 1：建底）
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 目的：把「案件清單 / 成員名單」這兩支「高頻讀取」改成從 Supabase 讀，繞過
--       會被 Google 間歇安全頁攔截的 GAS 通道 → 開頁變快、不再一片 0、少重試。
--
-- 安全設計（最重要）：
--   1. cases_mirror 這張表【直接讀一律擋】(RLS 開、無 select policy)。
--      → 就算有人拿 anon/authenticated 金鑰直打 REST，也 select 不到任何一列。
--   2. 前端只能透過 get_my_cases() 這支「帶授權的讀取函式」拿資料；
--      函式在資料庫端【重現你現在的可見範圍規矩】：
--        管理者看全部 / 申請人看自己的 / email 在該案簽核鏈快照(chain_emails)裡的人看得到。
--      → 這是你現在 listCases 過濾的「子集」(暫不含生效代理人)，
--        所以【永遠不會多給】——資安上只會少給、不會外洩；代理人少看到的部分
--        由 Stage 2 影子比對抓出來後再補（維持零外洩）。
--   3. 寫入(同步)只能透過 cases_sync() RPC，且【限管理者】(沿用 _ht_is_admin())。
--
-- 依賴：JWT 需帶 email 與 app_roles（由 GAS sb-token.gs 簽入，午茶已在用同一把）。
--       ★ 先部署帶 app_roles 的 GAS、再跑本段；否則舊 token 沒 email/app_roles，
--         連本人都會讀不到，重整拿新 token 即恢復。
--
-- 這一段【只建表與函式，前端完全不動】。使用者看到的仍是舊 GAS 讀取，零風險、可回退。
-- ============================================================

-- ─────────────────────────────────────────────
-- A) 案件鏡像表
-- ─────────────────────────────────────────────
create table if not exists cases_mirror (
  case_id         text primary key,               -- 單號（EWC-… / DRAFT-…）
  applicant_email text,                            -- 申請人 email（小寫）— 可見範圍用
  chain_emails    text[] not null default '{}',    -- 該案簽核鏈快照的簽核人 email（小寫）— 可見範圍用
  status          text,                            -- 狀態（草稿/待第N關簽核/已完成/已退件/作廢）
  data            jsonb not null,                  -- listCases 產出的該案完整物件（原封，前端渲染邏輯不用改）
  synced_at       timestamptz default now()
);
create index if not exists idx_cases_mirror_applicant on cases_mirror(applicant_email);
create index if not exists idx_cases_mirror_chain     on cases_mirror using gin(chain_emails);
create index if not exists idx_cases_mirror_status    on cases_mirror(status);

-- RLS：開啟但【不建任何 select policy】→ 直接讀一律擋（anon 與 authenticated 皆然）。
-- 寫入由下方 SECURITY DEFINER 的同步 RPC 執行（definer 會繞過 RLS）。
alter table cases_mirror enable row level security;
-- 清掉可能殘留的舊寬鬆 policy，避免以 OR 疊加導致「直接讀」被放行。
do $$
declare pol record;
begin
  for pol in select policyname from pg_policies
             where schemaname='public' and tablename='cases_mirror'
  loop execute format('drop policy if exists %I on public.cases_mirror', pol.policyname); end loop;
end $$;

-- ─────────────────────────────────────────────
-- B) 帶授權的讀取函式：只回「我有權看」的案件（永不多給）
--    可見範圍 = 管理者 OR 申請人本人 OR email 在簽核鏈快照裡
--    （暫不含「生效代理人」；那條 Stage 2 影子比對確認後再補，期間只會少看、不會外洩）
-- ─────────────────────────────────────────────
create or replace function get_my_cases() returns setof jsonb
  language sql stable security definer set search_path = public, extensions as $$
  select data
    from cases_mirror
   where ((auth.jwt() -> 'app_roles') ? 'manager')                                  -- 管理者：全部
      or applicant_email = lower(coalesce(auth.jwt() ->> 'email', ''))              -- 申請人本人
      or lower(coalesce(auth.jwt() ->> 'email', '')) = any(chain_emails)            -- 在簽核鏈上的人
   order by (data ->> 'createdAt') desc;
$$;
-- 只給已登入者執行；明確收回 public/anon，避免未授權呼叫。
revoke execute on function get_my_cases() from public;
revoke execute on function get_my_cases() from anon;
grant  execute on function get_my_cases() to   authenticated;

-- ─────────────────────────────────────────────
-- C) 同步 RPC：GAS 把「全部案件（未過濾）」整包丟進來 upsert（限管理者）
--    p_cases = listCases 內部產出的案件物件陣列（含 caseId/email/status/chainEmails…）
-- ─────────────────────────────────────────────
create or replace function cases_sync(p_cases jsonb) returns jsonb
  language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0;
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_cases is null or jsonb_typeof(p_cases) <> 'array' then
    return jsonb_build_object('ok', false, 'error', '缺少案件資料');
  end if;

  insert into cases_mirror (case_id, applicant_email, chain_emails, status, data, synced_at)
  select c ->> 'caseId',
         lower(coalesce(c ->> 'email', '')),
         coalesce(
           (select array_agg(lower(x))
              from jsonb_array_elements_text(
                     case when jsonb_typeof(c -> 'chainEmails') = 'array'
                          then c -> 'chainEmails' else '[]'::jsonb end) as x
             where coalesce(x, '') <> ''),
           '{}'
         ),
         c ->> 'status',
         c,
         now()
    from jsonb_array_elements(p_cases) as c
   where coalesce(c ->> 'caseId', '') <> ''
  on conflict (case_id) do update
     set applicant_email = excluded.applicant_email,
         chain_emails    = excluded.chain_emails,
         status          = excluded.status,
         data            = excluded.data,
         synced_at       = now();

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'synced', n,
                            'total', (select count(*) from cases_mirror));
end $$;
revoke execute on function cases_sync(jsonb) from public;
revoke execute on function cases_sync(jsonb) from anon;
grant  execute on function cases_sync(jsonb) to   authenticated;   -- 實際仍由 _ht_is_admin() 內部再擋一層

-- ─────────────────────────────────────────────
-- D) 成員鏡像表（getMembers）
--    成員名單（姓名/部門/角色/生日/頭貼）現況本來就對「所有已登入者」開放（供名字標籤、
--    下拉、壽星使用），故沿用午茶歷史表的作法：authenticated 唯讀；寫入限管理者 RPC。
-- ─────────────────────────────────────────────
create table if not exists members_mirror (
  email     text primary key,
  data      jsonb not null,          -- getMembers 回傳的該成員物件（原封）
  synced_at timestamptz default now()
);
alter table members_mirror enable row level security;
drop policy if exists p_members_mirror_read on members_mirror;
create policy p_members_mirror_read on members_mirror for select to authenticated using (true);

create or replace function members_sync(p_members jsonb) returns jsonb
  language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0;
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_members is null or jsonb_typeof(p_members) <> 'array' then
    return jsonb_build_object('ok', false, 'error', '缺少成員資料');
  end if;

  insert into members_mirror (email, data, synced_at)
  select lower(m ->> 'email'), m, now()
    from jsonb_array_elements(p_members) as m
   where coalesce(m ->> 'email', '') <> ''
  on conflict (email) do update
     set data = excluded.data, synced_at = now();

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'synced', n,
                            'total', (select count(*) from members_mirror));
end $$;
revoke execute on function members_sync(jsonb) from public;
revoke execute on function members_sync(jsonb) from anon;
grant  execute on function members_sync(jsonb) to   authenticated;

-- ─────────────────────────────────────────────
-- E) 驗證用（選跑）——確認「直接讀被擋、函式讀得到」
-- ─────────────────────────────────────────────
-- 直接讀應回 0 列（被 RLS 擋；只有透過 get_my_cases() 才拿得到）：
--   select count(*) from cases_mirror;              -- 預期：0（除非你是 service_role）
-- 用目前登入者身分測可見範圍（在前端 htSupabase 呼叫 rpc/get_my_cases）：
--   select * from get_my_cases();
-- 看兩張表目前的 policy：
--   select tablename, policyname, cmd, roles from pg_policies
--    where schemaname='public' and tablename in ('cases_mirror','members_mirror')
--    order by tablename, policyname;
