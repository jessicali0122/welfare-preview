-- ============================================================
-- 共用設定鏡像（申請項目／供應商／簽核流程設定）— Migration 12（Stage 6）
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 目的：把登入時 bootstrap 必抓的三支「設定類讀取」搬離 GAS，減少登入撞 Google 安全牆的機會。
--   getApplyItems  → 申請項目清單（[{name, needsHR}]）
--   getSuppliers   → 供應商清單（[{code, name}]）
--   getFlowInfo    → 簽核關卡設定（[{name, email, enabled, condition, onLeave, proxyEmail}]）
--
-- 【權限等價性論證（重要）】三支在 GAS 端的現況：
--   * 後端 doPost 在路由到任何 action 之前，一律先 verifyUser(data.token)，失敗回「請先登入公司帳號」
--     → 因此以下三支都是「必須用公司帳號登入」才拿得到，不存在匿名可讀。
--   * getApplyItems / getFlowInfo：登入後【無任何角色檢查】，所有登入者拿到同一份。
--   * getSuppliers：只檢查 user.email 存在（＝已登入），同樣所有登入者拿到同一份。
--   → 故鏡像 RLS 採「authenticated 可讀」＝與現況完全等價，不放寬也不收緊。
--
-- 【為什麼簽核流程設定不收緊】
--   系統有「職務代理人／休假代理人」機制，代理人需要讀這份設定才知道自己正在代班
--   （前端 _canViewAllCasesFE 會比對 onLeave/proxyEmail），而代理人不一定具備福委角色。
--   若照 getFlow 的嚴格規則收緊，代理人會讀不到 → 簽核按鈕消失、代理功能壞掉。
--   因此這裡刻意維持與 getFlowInfo 相同的可見範圍（所有登入者），零行為改變。
--
-- 寫入一律只走 GAS（saveApplyItems 限管理者、供應商增修刪、saveFlow），鏡像只是唯讀快取。
-- ============================================================

-- ─────────────────────────────────────────────
-- A) 設定鏡像表：一列一種設定，value 存原封的 JSON
-- ─────────────────────────────────────────────
create table if not exists config_mirror (
  key       text primary key,        -- 'apply_items' | 'suppliers' | 'flow_approvers'
  value     jsonb not null,          -- GAS 原始回傳的陣列（原封，前端渲染邏輯不用改）
  synced_at timestamptz default now()
);

alter table config_mirror enable row level security;
-- 清掉可能殘留的舊 policy，避免以 OR 疊加放寬
do $$
declare pol record;
begin
  for pol in select policyname from pg_policies
             where schemaname='public' and tablename='config_mirror'
  loop execute format('drop policy if exists %I on public.config_mirror', pol.policyname); end loop;
end $$;
-- 已登入者可讀（與 GAS 現況等價：三支都是登入即可取得同一份）；未登入無 JWT → 一律讀不到
create policy p_config_mirror_read on config_mirror for select to authenticated using (true);

-- ─────────────────────────────────────────────
-- B) 同步 RPC：GAS 把設定整包丟進來 upsert（限管理者）
--    p_items = [{key, value}...]，只 upsert 傳入的 key，不刪其他 key
--    （設定種類是程式碼決定的固定集合，不存在「要清掉舊 key」的情境）
-- ─────────────────────────────────────────────
create or replace function config_sync(p_items jsonb) returns jsonb
  language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0;
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'error', '缺少設定資料');
  end if;

  insert into config_mirror (key, value, synced_at)
  select c ->> 'key', c -> 'value', now()
    from jsonb_array_elements(p_items) as c
   where coalesce(c ->> 'key', '') <> ''
     and (c -> 'value') is not null
     -- 空陣列不覆蓋既有值：GAS 端萬一讀失敗回空，不要把好的設定蓋掉（設定為空會讓下拉全空）
     and not (jsonb_typeof(c -> 'value') = 'array' and jsonb_array_length(c -> 'value') = 0)
  on conflict (key) do update
     set value = excluded.value, synced_at = now();

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'synced', n,
                            'keys', (select coalesce(jsonb_agg(key order by key), '[]'::jsonb) from config_mirror));
end $$;
revoke execute on function config_sync(jsonb) from public;
revoke execute on function config_sync(jsonb) from anon;
grant  execute on function config_sync(jsonb) to   authenticated;   -- 實際仍由 _ht_is_admin() 內部再擋一層

-- ─────────────────────────────────────────────
-- C) 驗證用（選跑）
-- ─────────────────────────────────────────────
--   select key, jsonb_array_length(value) as n, synced_at from config_mirror order by key;
--   未登入（只有公開金鑰）讀 config_mirror 應回 0 列
