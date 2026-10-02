-- ============================================================
-- 按摩規則修正（2026-10-02）：①已取消的預約不可再被接受轉讓 ②停用者不可候補、也不會被自動補上 ③同一人同時送出多筆預約不再突破上限 ④結算缺席只算已開始超過 15 分鐘的時段
-- 在 Supabase → SQL Editor 貼上整段執行（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 問題（正式環境交易內實測確認）：A 發起轉讓 → A 自己取消 → B 仍可按「接受」，
--   結果該筆狀態 cancelled、持有人卻變成 B，資料錯亂。
-- 修正：
--   1) massage_accept_transfer：上鎖後確認預約仍是 booked 且時段尚未開始，否則擋下
--   2) massage_cancel：與接受轉讓用同一把鎖（ms_booking|<id>），取消時一併清掉待接受的轉讓邀請
--   3) massage_join_waitlist：停用（違規 ≥3）的人不能加入候補
--   4) _ms_promote_from_waitlist：遞補時跳過已停用的候補者（該筆標為 cancelled 並留紀錄），改補下一位
--   5) massage_book：多加一把「每人」的鎖（ms_user|<email>），同一人兩個分頁同時送出時會依序處理，
--      第二筆才看得到第一筆 → 一天一次／每月 2 次正確擋下（原本只鎖「日期+時段」）
--   6) massage_mark_noshow：只把「開始時間已過 15 分鐘」仍未報到的預約記為缺席
--      （原本整天所有 booked 一次標掉 → 當天提早按結算，還沒輪到的人也會被記缺席）
-- 候補轉正的預約（WL 開頭）不計入每月 2 次是刻意的（使用者 2026-10-02 確認）。
-- 轉讓不受「一天一次」「每月 2 次」限制是刻意的（使用者 2026-10-02 確認），這裡不加該檢查。
-- 其餘邏輯與線上版（21 / 16 號檔）完全相同。
-- ============================================================

CREATE OR REPLACE FUNCTION public.massage_accept_transfer(p_booking_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := _ms_jwt_email();
  v_row massage_bookings;
  v_violation int;
begin
  perform pg_advisory_xact_lock(hashtext('ms_booking|' || p_booking_id));
  select * into v_row from massage_bookings where booking_id = p_booking_id for update;
  if v_row is null then return jsonb_build_object('ok', false, 'error', '找不到預約'); end if;
  if v_row.transfer_status is distinct from 'pending' or v_row.transfer_to_email is distinct from v_email then
    return jsonb_build_object('ok', false, 'error', '沒有邀請你接受這筆轉讓，或邀請已失效');
  end if;
  -- ★ 新增：原預約已取消／已結束／已報到 → 不可接受
  if v_row.status <> 'booked' then
    return jsonb_build_object('ok', false, 'error', '這筆預約已取消或已失效，無法接受轉讓');
  end if;
  if (v_row.date::timestamp + v_row.time_slot::interval) <= (now() at time zone 'Asia/Taipei') then
    return jsonb_build_object('ok', false, 'error', '時段已開始，無法接受轉讓');
  end if;
  select coalesce((value->>v_email)::int,0) into v_violation from massage_settings where key='violationCounts';
  if coalesce(v_violation,0) >= 3 then return jsonb_build_object('ok', false, 'error', '帳號已停用，無法接受轉讓'); end if;

  update massage_bookings
     set user_email = v_email, user_name = coalesce(v_row.transfer_to_name, v_email),
         transfer_status = null, transfer_to_email = null, transfer_to_name = null, transfer_invited_at = null,
         updated_at = now()
   where booking_id = p_booking_id;

  insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
  values ('massageAcceptTransfer', v_email, v_email, v_row.user_email, p_booking_id, v_row.date, v_row.time_slot, '接受轉讓（原預約人：' || v_row.user_email || '）');
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.massage_cancel(p_booking_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := _ms_jwt_email();
  v_row massage_bookings;
  v_deadline_hours numeric := 0.5;
  v_diff_hours numeric;
begin
  if p_booking_id is null then return jsonb_build_object('ok', false, 'error', '缺少 bookingId'); end if;
  -- ★ 新增：與接受轉讓同一把鎖，避免「取消」與「接受轉讓」同時發生
  perform pg_advisory_xact_lock(hashtext('ms_booking|' || p_booking_id));
  select * into v_row from massage_bookings where booking_id = p_booking_id for update;
  if v_row is null then return jsonb_build_object('ok', false, 'error', '找不到預約'); end if;
  if v_row.user_email <> v_email then return jsonb_build_object('ok', false, 'error', '無權取消他人預約'); end if;
  if v_row.status <> 'booked' then return jsonb_build_object('ok', false, 'error', '預約狀態不可取消'); end if;

  v_diff_hours := extract(epoch from ((v_row.date::timestamp + v_row.time_slot::interval) - (now() at time zone 'Asia/Taipei'))) / 3600.0;
  if v_diff_hours < v_deadline_hours then
    return jsonb_build_object('ok', false, 'error', '距離時段不足 30 分鐘，已無法取消；若臨時無法前來請聯絡福委');
  end if;

  perform pg_advisory_xact_lock(hashtext(v_row.date::text || '|' || v_row.time_slot));
  -- ★ 新增：取消時一併清掉待接受的轉讓邀請
  update massage_bookings
     set status='cancelled', updated_at=now(),
         transfer_status = null, transfer_to_email = null, transfer_to_name = null, transfer_invited_at = null
   where booking_id=p_booking_id;
  insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
  values ('massageCancel', v_email, v_email, v_email, p_booking_id, v_row.date, v_row.time_slot, '自行取消');

  perform _ms_promote_from_waitlist(v_row.date, v_row.time_slot);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.massage_join_waitlist(p_date date, p_time_slot text, p_user_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := _ms_jwt_email();
  v_open_dates jsonb;
  v_slot jsonb;
  v_capacity int;
  v_booked_count int;
  v_waitlist_id text;
  v_position int;
  v_violation int;
begin
  if v_email = '' then return jsonb_build_object('ok', false, 'error', '未登入'); end if;
  -- ★ 新增：停用者不能候補（與 massage_book 同一條規則）
  select coalesce((value->>v_email)::int,0) into v_violation from massage_settings where key='violationCounts';
  if coalesce(v_violation,0) >= 3 then return jsonb_build_object('ok', false, 'error', '帳號已停用，無法候補'); end if;

  select value into v_open_dates from massage_settings where key='openDates';
  if v_open_dates is null or not (v_open_dates ? p_date::text) then
    return jsonb_build_object('ok', false, 'error', '該日期未開放預約');
  end if;
  select s into v_slot from jsonb_array_elements(v_open_dates->p_date::text->'slots') s where s->>'time' = p_time_slot;
  if v_slot is null then return jsonb_build_object('ok', false, 'error', '該時段不存在'); end if;
  v_capacity := coalesce((v_slot->>'capacity')::int, 1);

  select count(*) into v_booked_count from massage_bookings where date=p_date and time_slot=p_time_slot and status='booked';
  if v_booked_count < v_capacity then return jsonb_build_object('ok', false, 'error', '該時段尚有空位，請直接預約'); end if;

  if exists (select 1 from massage_bookings where user_email=v_email and date=p_date and time_slot=p_time_slot and status='booked') then
    return jsonb_build_object('ok', false, 'error', '您已預約此時段');
  end if;
  if exists (select 1 from massage_waitlist where user_email=v_email and date=p_date and time_slot=p_time_slot and status='waiting') then
    return jsonb_build_object('ok', false, 'error', '您已在此時段候補中');
  end if;

  v_waitlist_id := 'WL' || floor(extract(epoch from clock_timestamp())*1000)::bigint;
  insert into massage_waitlist (waitlist_id, date, time_slot, user_email, user_name, status)
  values (v_waitlist_id, p_date, p_time_slot, v_email, coalesce(p_user_name, v_email), 'waiting');

  insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
  values ('massageJoinWaitlist', v_email, coalesce(p_user_name, v_email), v_email, v_waitlist_id, p_date, p_time_slot, '加入候補');

  select count(*) into v_position from massage_waitlist where date=p_date and time_slot=p_time_slot and status='waiting';
  return jsonb_build_object('ok', true, 'waitlistId', v_waitlist_id, 'position', v_position);
end $function$;

-- 遞補：照排隊順序找第一位「未停用」的候補者轉正；停用者那筆標 cancelled 並留紀錄（不會卡住後面的人）
CREATE OR REPLACE FUNCTION public._ms_promote_from_waitlist(p_date date, p_time_slot text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_next massage_waitlist;
  v_booking_id text;
  v_now timestamptz := now();
  v_vc jsonb;
begin
  select coalesce(value, '{}'::jsonb) into v_vc from massage_settings where key='violationCounts';
  v_vc := coalesce(v_vc, '{}'::jsonb);
  for v_next in
    select * from massage_waitlist
     where date = p_date and time_slot = p_time_slot and status = 'waiting'
     order by created_at asc
  loop
    if coalesce((v_vc->>v_next.user_email)::int, 0) >= 3 then
      update massage_waitlist set status='cancelled', updated_at=v_now where waitlist_id = v_next.waitlist_id;
      insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
      values ('massageWaitlistSkipSuspended', v_next.user_email, v_next.user_name, v_next.user_email, v_next.waitlist_id, p_date, p_time_slot, '帳號已停用，候補略過');
      continue;
    end if;

    update massage_waitlist set status='promoted', updated_at=v_now where waitlist_id = v_next.waitlist_id;
    v_booking_id := 'WL' || floor(extract(epoch from clock_timestamp())*1000)::bigint;
    insert into massage_bookings (booking_id, date, time_slot, user_email, user_name, status)
    values (v_booking_id, p_date, p_time_slot, v_next.user_email, v_next.user_name, 'booked');
    insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
    values ('massagePromoteFromWaitlist', v_next.user_email, v_next.user_name, v_next.user_email, v_booking_id, p_date, p_time_slot, '候補轉正');
    return;
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION public.massage_book(p_date date, p_time_slot text, p_user_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := _ms_jwt_email();
  v_open_dates jsonb;
  v_slot jsonb;
  v_capacity int;
  v_booked_count int;
  v_monthly_count int;
  v_violation int;
  v_booking_id text;
begin
  if v_email = '' then return jsonb_build_object('ok', false, 'error', '未登入'); end if;
  if p_date is null or p_time_slot is null then return jsonb_build_object('ok', false, 'error', '缺少 date 或 timeSlot'); end if;

  -- ★ 新增：先鎖「這個人」（同一人的多筆請求依序處理），再鎖「日期+時段」；順序固定，不會互卡
  perform pg_advisory_xact_lock(hashtext('ms_user|' || v_email));
  perform pg_advisory_xact_lock(hashtext(p_date::text || '|' || p_time_slot));

  if (p_date::timestamp + p_time_slot::interval) <= (now() at time zone 'Asia/Taipei') then
    return jsonb_build_object('ok', false, 'error', '該時段已過，無法預約');
  end if;

  select coalesce((value->>v_email)::int,0) into v_violation from massage_settings where key='violationCounts';
  if coalesce(v_violation,0) >= 3 then return jsonb_build_object('ok', false, 'error', '帳號已停用，無法預約'); end if;

  select value into v_open_dates from massage_settings where key='openDates';
  if v_open_dates is not null and jsonb_typeof(v_open_dates) = 'object' and (v_open_dates ? p_date::text) then
    select s into v_slot from jsonb_array_elements(v_open_dates->p_date::text->'slots') s where s->>'time' = p_time_slot;
    if v_slot is null then return jsonb_build_object('ok', false, 'error', '該時段不存在'); end if;
    v_capacity := coalesce((v_slot->>'capacity')::int, 1);
  elsif v_open_dates is not null and jsonb_typeof(v_open_dates) = 'object' and jsonb_object_keys_count(v_open_dates) > 0 then
    return jsonb_build_object('ok', false, 'error', '該日期未開放預約');
  else
    v_capacity := 1;
  end if;

  select count(*) into v_monthly_count from massage_bookings
   where user_email = v_email and to_char(date,'YYYY-MM') = to_char(p_date,'YYYY-MM')
     and booking_id not like 'WL%' and status in ('booked','attended');
  if v_monthly_count >= 2 then
    return jsonb_build_object('ok', false, 'error', '已達該月預約上限 2 次');
  end if;

  select count(*) into v_booked_count from massage_bookings where date=p_date and time_slot=p_time_slot and status='booked';
  if v_booked_count >= v_capacity then return jsonb_build_object('ok', false, 'error', '該時段已額滿'); end if;

  if exists (select 1 from massage_bookings where user_email=v_email and date=p_date and status in ('booked','attended')) then
    return jsonb_build_object('ok', false, 'error', '同一天只能預約一次按摩');
  end if;

  v_booking_id := 'BK' || floor(extract(epoch from clock_timestamp())*1000)::bigint;
  insert into massage_bookings (booking_id, date, time_slot, user_email, user_name, status)
  values (v_booking_id, p_date, p_time_slot, v_email, coalesce(p_user_name, v_email), 'booked');

  insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
  values ('massageBook', v_email, coalesce(p_user_name, v_email), v_email, v_booking_id, p_date, p_time_slot, '');

  return jsonb_build_object('ok', true, 'bookingId', v_booking_id);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', '已有相同時段預約');
end $function$;

CREATE OR REPLACE FUNCTION public.massage_mark_noshow(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := _ms_jwt_email();
  v_violation_counts jsonb;
  v_penalty int := 3;
  r record;
  v_count int := 0;
  v_new_count int;
begin
  if not _ms_is_admin_or_hr() then return jsonb_build_object('ok', false, 'error', '無管理權限'); end if;
  if p_date is null then return jsonb_build_object('ok', false, 'error', '缺少 date'); end if;

  perform pg_advisory_xact_lock(hashtext('ms_violation_counts'));
  select coalesce(value, '{}'::jsonb) into v_violation_counts from massage_settings where key='violationCounts';
  if v_violation_counts is null then v_violation_counts := '{}'::jsonb; end if;

  -- ★ 修正：只處理「開始已超過 15 分鐘」的時段（報到窗：超過 15 分鐘視同未到）
  for r in select * from massage_bookings
            where date = p_date and status = 'booked'
              and (date::timestamp + time_slot::interval + interval '15 minutes') <= (now() at time zone 'Asia/Taipei')
  loop
    update massage_bookings set status='noshow', updated_at=now() where booking_id = r.booking_id;
    v_new_count := coalesce((v_violation_counts->>r.user_email)::int, 0) + 1;
    v_violation_counts := jsonb_set(v_violation_counts, array[r.user_email], to_jsonb(v_new_count), true);
    insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
    values ('massageMarkNoshow', v_email, v_email, r.user_email, r.booking_id, p_date, r.time_slot, '標記缺席');
    v_count := v_count + 1;
  end loop;

  insert into massage_settings (key, value, updated_at) values ('violationCounts', v_violation_counts, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();

  return jsonb_build_object('ok', true, 'count', v_count);
end $function$;

-- 權限與原本相同（CREATE OR REPLACE 會保留既有 grant，這裡再宣告一次保險）
revoke execute on function massage_accept_transfer(text) from public, anon;
grant  execute on function massage_accept_transfer(text) to authenticated;
revoke execute on function massage_cancel(text) from public, anon;
grant  execute on function massage_cancel(text) to authenticated;
revoke execute on function massage_join_waitlist(date, text, text) from public, anon;
grant  execute on function massage_join_waitlist(date, text, text) to authenticated;
revoke execute on function massage_book(date, text, text) from public, anon;
grant  execute on function massage_book(date, text, text) to authenticated;
revoke execute on function massage_mark_noshow(date) from public, anon;
grant  execute on function massage_mark_noshow(date) to authenticated;
