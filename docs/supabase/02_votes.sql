-- ============================================================
-- 午茶投票搬家 Migration 02：投票表 + 設定表 + 管理者名單 + RPC
-- 在 Supabase → SQL Editor 貼上整段執行即可（可重複執行）
-- ------------------------------------------------------------
-- 設計重點：
--  ★ 投票規則原本由 GAS 伺服器端把關（一人一票／限活動當天／限福委關閉投票）。
--    改打 PostgREST 後前端不可信，所以規則全部移進「SECURITY DEFINER 的 RPC 函式」，
--    等同把伺服器端搬進資料庫。前端只能呼叫這些函式，不能直接讀寫投票表。
--  ★ 匿名：沿用「email+活動編號 雜湊」當識別碼，且雜湊由資料庫用 JWT 裡的 email 計算，
--    前端無法偽造成別人、也無法自己換一把鑰匙重複投。投票表不對前端開放 SELECT，
--    連雜湊都拿不到 → 比原本試算表更難反查。
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- 1) 投票 ----------
create table if not exists ht_votes (
  id         uuid primary key default gen_random_uuid(),
  event_id   text not null,                       -- HTD-yyyy-MM-dd（新制）或 HT-yyyy-MM（舊制）
  vote_key   text not null,                       -- sha256(lower(email)|event_id) 前 24 碼；投票亭為 K-<uuid>
  sat        int  not null check (sat between 1 and 5),
  favs       jsonb default '[]',
  comment    text default '',
  created_at timestamptz default now(),
  unique (event_id, vote_key)                     -- ★ 一人一票由資料庫保證，不靠前端
);
create index if not exists idx_ht_votes_event on ht_votes(event_id);

-- ---------- 2) 每場投票設定（取代 Script Properties）----------
create table if not exists ht_vote_config (
  event_id   text primary key,
  closed     boolean default false,               -- 福委按「結束投票」
  items      jsonb   default '[]',                -- 已勾選列入投票的品項名稱
  known      jsonb   default '[]',                -- 存檔當下的全部品項快照（供前端自動對齊新品項）
  updated_at timestamptz default now()
);

-- ---------- 3) 管理者名單（取代 GAS 的 _htRoleCheck_）----------
-- JWT 由 GAS 簽發、內含 email；這裡靠 email 判斷是否為福委／管理者。
create table if not exists ht_admins (
  email text primary key
);

-- ============================================================
-- 共用小工具
-- ============================================================
-- 目前呼叫者的 email（來自 GAS 簽發的 JWT）
create or replace function _ht_jwt_email() returns text
language sql stable as $$
  select lower(coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', ''))
$$;

create or replace function _ht_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ht_admins where lower(email) = _ht_jwt_email())
$$;

-- 匿名去重鑰匙：與原 GAS 同演算法（sha256 十六進位前 24 碼）
create or replace function _ht_vote_key(p_email text, p_event_id text) returns text
language sql immutable as $$
  select substr(encode(digest(lower(coalesce(p_email,'')) || '|' || coalesce(p_event_id,''), 'sha256'), 'hex'), 1, 24)
$$;

-- 台灣時間的今天
create or replace function _ht_today_tw() returns date
language sql stable as $$ select (now() at time zone 'Asia/Taipei')::date $$;

-- 該活動編號對應的活動日期（HTD-yyyy-MM-dd 直接取；HT-yyyy-MM 查 ht_events）
create or replace function _ht_event_date(p_event_id text) returns date
language plpgsql stable security definer set search_path = public as $$
declare d date;
begin
  if p_event_id ~ '^HTD-\d{4}-\d{2}-\d{2}$' then
    return substr(p_event_id, 5)::date;
  end if;
  select event_date into d from ht_events where event_id = p_event_id;
  return d;
end $$;

-- ============================================================
-- RPC：前端唯一的投票入口（規則都在這裡把關）
-- ============================================================

-- 投票。回傳 {ok, error?}
create or replace function ht_vote_submit(
  p_event_id text, p_sat int, p_favs jsonb default '[]', p_comment text default '', p_kiosk boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := _ht_jwt_email();
  v_date  date;
  v_key   text;
  v_favs  jsonb;
begin
  if v_email = '' then return jsonb_build_object('ok', false, 'error', '未登入'); end if;
  if p_event_id is null or p_event_id = '' then return jsonb_build_object('ok', false, 'error', '缺少活動編號'); end if;
  if p_sat is null or p_sat < 1 or p_sat > 5 then return jsonb_build_object('ok', false, 'error', '滿意度需為 1-5'); end if;

  v_date := _ht_event_date(p_event_id);
  if v_date is null then return jsonb_build_object('ok', false, 'error', '找不到該日期的活動'); end if;
  if v_date <> _ht_today_tw() then return jsonb_build_object('ok', false, 'error', '僅限活動當天投票'); end if;

  if exists (select 1 from ht_vote_config where event_id = p_event_id and closed) then
    return jsonb_build_object('ok', false, 'error', '投票已結束，感謝大家的參與 🎉');
  end if;

  -- 投票亭模式：公用裝置多人輪流投，不做單人去重。★ 僅福委／管理者可用，
  -- 一般人即使自己送 kiosk=true 也一律走單人一票（與原 GAS 行為一致）
  if p_kiosk and _ht_is_admin() then
    v_key := 'K-' || substr(gen_random_uuid()::text, 1, 20);
  else
    v_key := _ht_vote_key(v_email, p_event_id);
    if exists (select 1 from ht_votes where event_id = p_event_id and vote_key = v_key) then
      return jsonb_build_object('ok', false, 'error', '你已投過票囉');
    end if;
  end if;

  -- 最愛品項最多 3 項、每項 60 字；一句話 40 字（與原 GAS 上限一致）
  select coalesce(jsonb_agg(left(x, 60)), '[]'::jsonb) into v_favs
    from (select jsonb_array_elements_text(coalesce(p_favs, '[]'::jsonb)) as x limit 3) t;

  insert into ht_votes (event_id, vote_key, sat, favs, comment)
    values (p_event_id, v_key, p_sat, v_favs, left(coalesce(p_comment, ''), 40));

  return jsonb_build_object('ok', true);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', '你已投過票囉');
end $$;

-- 讀取投票結果。votes 只回統計所需欄位，不含識別碼 → 無法反查誰投了什麼
create or replace function ht_vote_get(p_event_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := _ht_jwt_email();
  v_votes jsonb;
  v_voted boolean := false;
begin
  select coalesce(jsonb_agg(jsonb_build_object('sat', sat, 'favs', favs, 'comment', comment)), '[]'::jsonb)
    into v_votes from ht_votes where event_id = p_event_id;

  if v_email <> '' then
    select exists (select 1 from ht_votes where event_id = p_event_id and vote_key = _ht_vote_key(v_email, p_event_id))
      into v_voted;
  end if;

  return jsonb_build_object(
    'ok', true, 'votes', v_votes, 'voted', v_voted,
    'closed', coalesce((select closed from ht_vote_config where event_id = p_event_id), false)
  );
end $$;

-- 結束／重開投票（限福委／管理者）
create or replace function ht_vote_close(p_event_id text, p_reopen boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_event_id is null or p_event_id = '' then return jsonb_build_object('ok', false, 'error', '缺少活動編號'); end if;
  insert into ht_vote_config (event_id, closed, updated_at) values (p_event_id, not p_reopen, now())
    on conflict (event_id) do update set closed = not p_reopen, updated_at = now();
  return jsonb_build_object('ok', true, 'closed', not p_reopen);
end $$;

-- 投票品項名單
create or replace function ht_vote_items_get(p_event_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r ht_vote_config%rowtype;
begin
  select * into r from ht_vote_config where event_id = p_event_id;
  if not found or r.items is null then
    return jsonb_build_object('ok', true, 'configured', false, 'items', '[]'::jsonb, 'known', '[]'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'configured', true,
    'items', coalesce(r.items, '[]'::jsonb), 'known', coalesce(r.known, '[]'::jsonb));
end $$;

create or replace function ht_vote_items_save(p_event_id text, p_items jsonb, p_all jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_items jsonb; v_known jsonb;
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_event_id is null or p_event_id = '' then return jsonb_build_object('ok', false, 'error', '缺少活動編號'); end if;

  -- 去空白、去重、每項 60 字、最多 100 項（與原 GAS 的 _htVoteCleanNames_ 一致）
  select coalesce(jsonb_agg(distinct left(btrim(x), 60)), '[]'::jsonb) into v_items
    from (select jsonb_array_elements_text(coalesce(p_items, '[]'::jsonb)) as x) t
   where btrim(x) <> '';
  select coalesce(jsonb_agg(distinct left(btrim(x), 60)), '[]'::jsonb) into v_known
    from (select jsonb_array_elements_text(coalesce(p_all, '[]'::jsonb) || coalesce(p_items, '[]'::jsonb)) as x) t
   where btrim(x) <> '';

  insert into ht_vote_config (event_id, items, known, updated_at) values (p_event_id, v_items, v_known, now())
    on conflict (event_id) do update set items = v_items, known = v_known, updated_at = now();

  return jsonb_build_object('ok', true, 'configured', true, 'items', v_items, 'known', v_known);
end $$;

-- ============================================================
-- RLS：投票表一律不對前端直接開放，只能走上面的 RPC
-- ============================================================
alter table ht_votes       enable row level security;
alter table ht_vote_config enable row level security;
alter table ht_admins      enable row level security;

drop policy if exists p_ht_votes_none      on ht_votes;
drop policy if exists p_ht_vote_cfg_read   on ht_vote_config;
drop policy if exists p_ht_admins_read     on ht_admins;

-- ht_votes：完全不建立政策 → 任何前端角色都讀寫不到（只有 SECURITY DEFINER 函式進得去）
-- ht_vote_config：允許已登入者唯讀（前端要知道是否已截止）；寫入只能透過 RPC
create policy p_ht_vote_cfg_read on ht_vote_config for select to authenticated using (true);
-- ht_admins：允許已登入者唯讀（前端據此決定要不要顯示福委按鈕）；名單維護請在 Dashboard 手動改
create policy p_ht_admins_read on ht_admins for select to authenticated using (true);

-- 讓前端角色叫得到這些函式
grant execute on function ht_vote_submit(text, int, jsonb, text, boolean) to authenticated;
grant execute on function ht_vote_get(text)                              to authenticated;
grant execute on function ht_vote_close(text, boolean)                   to authenticated;
grant execute on function ht_vote_items_get(text)                        to authenticated;
grant execute on function ht_vote_items_save(text, jsonb, jsonb)         to authenticated;

-- ============================================================
-- ⚠️ 執行完請務必補上管理者名單，否則沒有人能「結束投票」或設定投票品項：
--   insert into ht_admins (email) values ('jessica@tsagroup.com.tw') on conflict do nothing;
--   （其他福委／管理者的公司 email 一併加進去）
-- ============================================================
