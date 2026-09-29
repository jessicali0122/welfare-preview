-- ============================================================
-- 按摩時段前 Chat 提醒：改讀 Supabase（原本讀舊試算表 → 搬家後的新預約收不到提醒）
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 背景（2026-09-24 發現）：
--   GAS 的 msSendReminders_ 掛在 keepWarm 每 5 分鐘觸發器上，一直直接讀試算表
--   massage_bookings。預約搬到 Supabase 後試算表不再有新資料 →
--   * 搬家後才預約的人收不到「前 40 分／前 5 分」提醒
--   * 試算表殘留的舊預約反而可能照舊資料發提醒
--
-- 本函式：一次完成「找出該提醒的預約」＋「標記已提醒」（UPDATE … RETURNING），
--   兩次觸發重疊也不會重複提醒。提醒時間點與原 GAS 版完全相同：
--   * 提醒①（remind40）：距開始 ≤40 分且 >5 分，且尚未發過
--   * 提醒②（remind5） ：距開始 ≤5 分且 ≥-3 分（開始後 3 分鐘內），且尚未發過
--   只處理 status='booked'（仍佔位）的預約；去重用表內既有的 rem40_sent_at / rem5_sent_at。
--
-- 權限：只有管理者 JWT（_ht_is_admin）可呼叫 —— GAS 以同步用的管理者身分簽 JWT 呼叫，
--   與 cases_sync 同一套。anon / public 不可執行。
-- ============================================================

create or replace function massage_claim_reminders()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_now timestamp := now() at time zone 'Asia/Taipei';
  v_out jsonb;
begin
  if not _ht_is_admin() then
    raise exception '僅限系統排程呼叫' using errcode = '42501';
  end if;

  with cand as (
    select booking_id, rem40_sent_at, rem5_sent_at,
           extract(epoch from ((date::timestamp + substring(time_slot from '^\d{1,2}:\d{2}')::interval) - v_now)) / 60.0 as mins
      from massage_bookings
     where status = 'booked'
       and date between v_now::date - 1 and v_now::date + 1       -- 只看前後一天，不掃全表
       and time_slot ~ '^\d{1,2}:\d{2}'                           -- 格式不對的列跳過，不讓整批失敗
  ),
  due as (
    select booking_id,
           case when rem40_sent_at is null and mins <= 40 and mins > 5  then 'remind40'
                when rem5_sent_at  is null and mins <= 5  and mins >= -3 then 'remind5'
           end as kind
      from cand
  ),
  upd as (
    update massage_bookings b
       set rem40_sent_at = case when d.kind = 'remind40' then now() else b.rem40_sent_at end,
           rem5_sent_at  = case when d.kind = 'remind5'  then now() else b.rem5_sent_at  end
      from due d
     where b.booking_id = d.booking_id
       and d.kind is not null
       and b.status = 'booked'
       -- 併發保護：鎖到列後重新檢查「還沒發過」（另一個同時執行的排程若已標記，這裡就不會再回傳）
       and ((d.kind = 'remind40' and b.rem40_sent_at is null)
         or (d.kind = 'remind5'  and b.rem5_sent_at  is null))
    returning b.booking_id, b.user_email, b.date, b.time_slot, d.kind
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'bookingId', booking_id,
           'email',     user_email,
           'date',      to_char(date, 'YYYY-MM-DD'),
           'timeSlot',  time_slot,
           'kind',      kind)), '[]'::jsonb)
    into v_out
    from upd;

  return v_out;
end $$;

-- 新函式預設會授權給 PUBLIC → 明確收回，只留登入者（函式內再以 _ht_is_admin 擋到只剩管理者）
revoke execute on function massage_claim_reminders() from public, anon;
grant  execute on function massage_claim_reminders() to authenticated;

-- ─────────────────────────────────────────────
-- 驗證：anon 應為 false、authenticated 應為 true
-- ─────────────────────────────────────────────
select has_function_privilege('anon',          'massage_claim_reminders()', 'execute') as anon_can_run,
       has_function_privilege('authenticated', 'massage_claim_reminders()', 'execute') as auth_can_run;
