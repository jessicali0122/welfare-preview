-- ============================================================
-- 成員鏡像「停用／刪除的人要跟著消失」— Migration 11（Stage 5 前置）
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 背景：getMembers 本來就會排除「停用中／disabled／deleted」的帳號，所以同步上拋的
--       p_members 是「目前仍在職成員」的完整名單。但原本 members_sync 只 upsert、不刪除，
--       因此某人被停用或刪除後，會永遠殘留在 members_mirror 裡 → 前端若改讀鏡像，
--       下拉選單、壽星名單、姓名對照都會出現已離職的人（也是個資面的問題）。
--
-- 做法：把「這次收到的完整成員名單」當唯一真相，鏡像裡不在名單內的舊列一併刪除。
-- 安全閘門（重要）：只有名單「非空」時才清理。若 GAS 端 getMembers 剛好失敗、
--       呼叫端送了空陣列，一律不清除，避免把整張成員鏡像清空（那會讓全站姓名顯示空白）。
--
-- 註：p_members 本身就是完整名單（getMembers 全量輸出），不像案件詳情那支需要另外帶
--     p_valid_ids——詳情是逐張抓、可能單張失敗而缺漏，成員則是一次整包拿，故可直接用它當基準。
-- ============================================================

create or replace function members_sync(p_members jsonb) returns jsonb
  language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0;
declare deleted_n int := 0;
declare valid_emails text[];
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

  -- ★ 清理：刪掉不在這次完整名單內的舊列（＝已停用／已刪除的帳號）。
  --   閘門：名單非空才清，避免呼叫端異常給空陣列時把整張表清空。
  select array_agg(lower(m ->> 'email')) into valid_emails
    from jsonb_array_elements(p_members) as m
   where coalesce(m ->> 'email', '') <> '';

  if valid_emails is not null and array_length(valid_emails, 1) > 0 then
    delete from members_mirror where email <> all (valid_emails);
    get diagnostics deleted_n = row_count;
  end if;

  return jsonb_build_object('ok', true, 'synced', n, 'deleted', deleted_n,
                            'total', (select count(*) from members_mirror));
end $$;
revoke execute on function members_sync(jsonb) from public;
revoke execute on function members_sync(jsonb) from anon;
grant  execute on function members_sync(jsonb) to   authenticated;   -- 實際仍由 _ht_is_admin() 內部再擋一層

-- ─────────────────────────────────────────────
-- 驗證用（選跑）
-- ─────────────────────────────────────────────
--   select count(*) from members_mirror;
--   前端（已登入者）可直接讀 members_mirror（與 getMembers 現況等價：全體已登入者皆可見）
