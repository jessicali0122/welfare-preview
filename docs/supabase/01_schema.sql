-- ============================================================
-- 午茶模組 Supabase 建表 Migration 01：schema + 彙總 + RLS
-- 在 Supabase → SQL Editor 貼上整段執行即可（可重複執行）
-- ============================================================

-- ---------- 1) 活動表 ----------
create table if not exists ht_events (
  event_id      text primary key,          -- HT-2026-08
  month         text not null,             -- 2026-08
  event_date    date,
  headcount     int  default 0,
  budget_pp     int  default 0,
  budget_total  int  default 0,
  actual_exp    numeric default 0,         -- 由 trigger 自動維護
  birthday_exp  numeric default 0,
  status        text default 'draft',
  birthdays     jsonb default '[]',        -- 壽星清單
  notes         text,
  reimburse_ref text,                       -- 報銷案件
  organizer1    text,
  organizer2    text,
  created_by    text,
  created_at    timestamptz default now(),
  completed_at  timestamptz,
  updated_at    timestamptz default now()
);

-- ---------- 2) 品項表 ----------
create table if not exists ht_items (
  item_id      text primary key,           -- ITM-uuid
  event_id     text references ht_events(event_id) on delete cascade,
  name         text,
  vendor       text,
  category     text default '其他',
  unit_price   numeric default 0,
  qty          int default 0,
  subtotal     numeric generated always as (unit_price * qty) stored,  -- 小計自動算
  serving      text,
  assignee     text,
  ordered      boolean default false,
  ordered_at   timestamptz,
  notes        text,
  rating_sum   int default 0,
  rating_count int default 0,
  avg_rating   numeric default 0,
  link         text,
  sort_order   int default 0,
  updated_at   timestamptz default now()
);
create index if not exists idx_ht_items_event on ht_items(event_id);

-- ---------- 3) 廠商表 ----------
create table if not exists ht_vendors (
  name          text primary key,
  category      text,
  total_orders  int default 0,
  rating_sum    int default 0,
  rating_count  int default 0,
  avg_rating    numeric default 0,
  last_used     text,
  tags          text
);

-- ============================================================
-- 彙總自動維護（取代 GAS 的 htRecalcExpense / htUpdateVendor + TextFinder）
-- ============================================================

-- 4) 品項變動 → 自動回寫該活動的實際支出
create or replace function ht_sync_event_expense() returns trigger
language plpgsql as $$
declare eid text;
begin
  eid := coalesce(new.event_id, old.event_id);
  update ht_events e
     set actual_exp = coalesce((select sum(subtotal) from ht_items where event_id = eid), 0),
         updated_at = now()
   where e.event_id = eid;
  return null;
end $$;

drop trigger if exists trg_ht_items_expense on ht_items;
create trigger trg_ht_items_expense
  after insert or update or delete on ht_items
  for each row execute function ht_sync_event_expense();

-- 5) 品項「已訂購」狀態變動 → 自動調整廠商訂購次數（+/-1）
create or replace function ht_sync_vendor_orders() returns trigger
language plpgsql as $$
begin
  -- 舊列若原本已訂購 → 該廠商 -1
  if (tg_op = 'UPDATE' or tg_op = 'DELETE') and old.ordered and old.vendor is not null and old.vendor <> '' then
    update ht_vendors set total_orders = greatest(total_orders - 1, 0) where name = old.vendor;
  end if;
  -- 新列若已訂購 → 該廠商 +1（廠商不存在則建立）
  if (tg_op = 'INSERT' or tg_op = 'UPDATE') and new.ordered and new.vendor is not null and new.vendor <> '' then
    insert into ht_vendors (name, category, total_orders)
      values (new.vendor, new.category, 1)
    on conflict (name) do update set total_orders = ht_vendors.total_orders + 1,
                                      last_used = coalesce(ht_vendors.last_used, '');
  end if;
  return null;
end $$;

drop trigger if exists trg_ht_items_vendor on ht_items;
create trigger trg_ht_items_vendor
  after insert or update or delete on ht_items
  for each row execute function ht_sync_vendor_orders();

-- ============================================================
-- Realtime：讓前端能訂閱 ht_items 的逐列變動
-- ============================================================
alter publication supabase_realtime add table ht_items;

-- ============================================================
-- RLS（列級安全）— 安全版（機密內部資料，不可公開外流）
-- ★ 只有「已驗證身分（authenticated）」可讀寫；anon（拿到公開 key 的路人）一律擋。
--   驗證身分＝前端帶一張「GAS 登入後簽發的 Supabase JWT」（role=authenticated）。
--   沒有這張 JWT 的請求一筆都讀不到 → 公開前端的 publishable key 單獨無用。
--   ⚠️ 前提：GAS 需用本專案的 JWT secret 簽 JWT（見 docs 說明），且勿建立任何 anon 政策。
-- ============================================================
alter table ht_events  enable row level security;
alter table ht_items   enable row level security;
alter table ht_vendors enable row level security;

-- 清掉任何舊的寬鬆政策（若曾建立過 anon 版）
drop policy if exists p_ht_events_all  on ht_events;
drop policy if exists p_ht_items_all   on ht_items;
drop policy if exists p_ht_vendors_all on ht_vendors;

-- 僅 authenticated 可全權存取；未建立 anon 政策 → RLS 預設拒絕 anon
create policy p_ht_events_auth  on ht_events  for all to authenticated using (true) with check (true);
create policy p_ht_items_auth   on ht_items   for all to authenticated using (true) with check (true);
create policy p_ht_vendors_auth on ht_vendors for all to authenticated using (true) with check (true);
