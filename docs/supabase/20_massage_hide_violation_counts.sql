-- ============================================================
-- 按摩 — Migration 20：不再把「全體違規／取消次數」發給每個人
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 問題：`violationCounts` / `cancelCounts` 是 email → 次數 的物件，
--   等同「誰被記了幾次缺席、誰快被停權」。目前有兩條外洩路徑：
--     (1) massage_get_data() 把整包 settings（含這兩個 key）回給每一個呼叫者；
--     (2) massage_settings 的 select policy 是 `to authenticated using (true)`，
--         任何員工用前端那把公開 key 直打 /rest/v1/massage_settings 就能整包讀走。
--   而 15_massage_schema.sql 檔頭明明宣告「操作紀錄只給管理者／HR」——
--   違規次數比操作紀錄更敏感，卻是全員可見。
--
-- 本檔修正：
--   (1) massage_get_data() 回傳的 settings 移除那兩個 key。
--       `suspended` 仍照舊在函式內部算好回傳（呼叫者只會知道「自己」有沒有被停權），
--       所以前端行為不變 —— 已確認 index.html 完全沒有讀取這兩個 key（只有一個本機預設值）。
--   (2) massage_settings 的 select policy 收斂成只放行畫面真正需要的兩個 key。
--       Realtime 仍可正常收到 openDates／slotTemplates 的變更事件（那才是前端訂閱的用途）；
--       管理端的寫入一律走 SECURITY DEFINER RPC，不受此 policy 影響。
--
-- 沒有改動的部分（刻意）：massage_bookings / massage_waitlist 維持
--   `to authenticated using (true)`。那是先前明確決定的設計——
--   「員工內部彼此看到沒關係，要擋的是非公司帳號」，且 Realtime 需要它才能收到
--   別人取消／候補轉正的事件。此處不動，避免為了稽核漂亮而弄壞即時更新。
-- ============================================================

-- ─────────────────────────────────────────────
-- 1) massage_get_data：settings 不再含 violationCounts / cancelCounts
--    （其餘欄位與原版逐字相同；已先比對線上定義確認無落差）
-- ─────────────────────────────────────────────
create or replace function massage_get_data() returns jsonb
  language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_email text := _ms_jwt_email();
  v_is_admin boolean := _ms_is_admin_or_hr();
  v_settings jsonb;          -- 對外回傳用（不含敏感次數）
  v_counts jsonb;            -- 僅函式內部用來算 suspended
  v_result jsonb;
begin
  -- 內部用：違規次數（只用來算呼叫者自己的 suspended，不回傳整包）
  select coalesce((select value from massage_settings where key='violationCounts'), '{}'::jsonb) into v_counts;

  select jsonb_build_object(
    'monthlyLimit', 2, 'cancelFreeLimit', 1, 'cancelDeadlineHours', 0.5, 'violationPenaltyCount', 3,
    'slotTemplates', coalesce((select value from massage_settings where key='slotTemplates'), '[]'::jsonb),
    'openDates',     coalesce((select value from massage_settings where key='openDates'), '{}'::jsonb)
  ) into v_settings;

  select jsonb_build_object(
    'ok', true,
    'userEmail', v_email,
    'myBookings', coalesce((
      select jsonb_agg(jsonb_build_object(
        'bookingId', booking_id, 'date', date, 'timeSlot', time_slot, 'userEmail', user_email,
        'userName', user_name, 'status', status, 'createdAt', created_at, 'updatedAt', updated_at,
        'cancelReason', cancel_reason,
        'deleteRequested', (cancel_reason = 'delete_requested'),
        'cancelRequested', (cancel_reason like 'cancel_requested%'),
        'transferStatus', transfer_status, 'transferToEmail', transfer_to_email, 'transferToName', transfer_to_name
      )) from massage_bookings where user_email = v_email and status <> 'deleted'
    ), '[]'::jsonb),
    'allBookings', coalesce((
      select jsonb_agg(jsonb_build_object('userName', user_name, 'date', date, 'timeSlot', time_slot, 'status', status))
      from massage_bookings where status in ('booked','attended')
    ), '[]'::jsonb),
    'adminBookings', case when v_is_admin then coalesce((
      select jsonb_agg(jsonb_build_object(
        'bookingId', booking_id, 'date', date, 'timeSlot', time_slot, 'userEmail', user_email,
        'userName', user_name, 'status', status, 'cancelReason', cancel_reason
      )) from massage_bookings where status <> 'deleted'
    ), '[]'::jsonb) else null end,
    'openDates', v_settings->'openDates',
    'settings', v_settings,
    'pendingRequests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'bookingId', booking_id, 'date', date, 'timeSlot', time_slot, 'userEmail', user_email,
        'userName', user_name, 'cancelReason', cancel_reason
      )) from massage_bookings
       where (cancel_reason like 'cancel_requested%' or cancel_reason = 'delete_requested')
         and (v_is_admin or user_email = v_email)
    ), '[]'::jsonb),
    'suspended', coalesce((v_counts->>v_email)::int, 0) >= 3,
    'monthlyCancelCount', 0,
    'myWaitlist', coalesce((
      select jsonb_agg(jsonb_build_object(
        'waitlistId', waitlist_id, 'date', date, 'timeSlot', time_slot, 'status', status,
        'position', (select count(*) from massage_waitlist w2
                      where w2.date = w1.date and w2.time_slot = w1.time_slot and w2.status='waiting' and w2.created_at <= w1.created_at)
      )) from massage_waitlist w1 where user_email = v_email and status = 'waiting'
    ), '[]'::jsonb),
    'waitlistCounts', coalesce((
      select jsonb_object_agg(date || '|' || time_slot, cnt) from (
        select date, time_slot, count(*) cnt from massage_waitlist where status='waiting' group by date, time_slot
      ) x
    ), '{}'::jsonb)
  ) into v_result;

  return v_result;
end $$;
revoke execute on function massage_get_data() from public;
revoke execute on function massage_get_data() from anon;
grant  execute on function massage_get_data() to   authenticated;

-- ─────────────────────────────────────────────
-- 2) massage_settings：直讀只放行畫面需要的兩個 key
-- ─────────────────────────────────────────────
drop policy if exists p_ms_settings_read on massage_settings;
create policy p_ms_settings_read on massage_settings
  for select to authenticated
  using (key in ('slotTemplates', 'openDates'));

-- ─────────────────────────────────────────────
-- 驗證（選跑）
-- ─────────────────────────────────────────────
-- 回傳的 settings 不應再有 violationCounts／cancelCounts：
--   select (select jsonb_agg(k order by k) from jsonb_object_keys(massage_get_data()->'settings') k);
-- 以一般員工身分直讀 massage_settings，應只看到 slotTemplates／openDates 兩列：
--   set local role authenticated;
--   select set_config('request.jwt.claims','{"role":"authenticated","email":"someone@tsagroup.com.tw"}',true);
--   select key from massage_settings order by key;
