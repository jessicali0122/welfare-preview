-- ============================================================
-- 按摩 — Migration 21：同事互轉預約 5 支 RPC（＋轉讓查詢）進版控
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 背景：這 6 支函式先前是直接在線上建立的，docs/supabase/ 底下沒有定義檔，
--   等於線上正在跑的程式不在版本控制內 —— 稽核查不到、也無法在別的環境重建。
--   本檔以 pg_get_functiondef 從線上撈回真實定義（2026-09-22），逐字保存。
--
-- 撈回後已逐項稽核，結果乾淨：
--   * 6 支全部有 SET search_path（無 search_path 劫持風險）
--   * 身分一律取自 _ms_jwt_email()（JWT），沒有任何「身分由參數決定」的寫法
--     （massage_offer_transfer 的 p_to_email 是「要轉給誰」，不是呼叫者身分，設計正確）
--   * 檔末補上明確的 revoke/grant：Postgres 對新建函式預設 grant execute to public，
--     而 grant ... to authenticated 不會移除那個預設權限（見 19_revoke_anon_execute.sql）。
--
-- 注意：massage_expire_transfers() 由 Supabase pg_cron 每 5 分鐘呼叫
--   （見 17_massage_transfer.sql），不是由前端或 GAS 觸發。
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
  select * into v_row from massage_bookings where booking_id = p_booking_id;
  if v_row is null then return jsonb_build_object('ok', false, 'error', '找不到預約'); end if;
  if v_row.transfer_status <> 'pending' or v_row.transfer_to_email <> v_email then
    return jsonb_build_object('ok', false, 'error', '沒有邀請你接受這筆轉讓，或邀請已失效');
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


CREATE OR REPLACE FUNCTION public.massage_decline_transfer(p_booking_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := _ms_jwt_email();
  v_row massage_bookings;
begin
  select * into v_row from massage_bookings where booking_id = p_booking_id;
  if v_row is null then return jsonb_build_object('ok', false, 'error', '找不到預約'); end if;
  if v_row.transfer_status <> 'pending' or v_row.transfer_to_email <> v_email then
    return jsonb_build_object('ok', false, 'error', '沒有邀請你回應這筆轉讓，或邀請已失效');
  end if;

  update massage_bookings set transfer_status=null, transfer_to_email=null, transfer_to_name=null, transfer_invited_at=null, updated_at=now()
   where booking_id = p_booking_id;
  insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
  values ('massageDeclineTransfer', v_email, v_email, v_row.user_email, p_booking_id, v_row.date, v_row.time_slot, '拒絕轉讓');
  return jsonb_build_object('ok', true);
end $function$;


CREATE OR REPLACE FUNCTION public.massage_expire_transfers()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  r record;
  v_count int := 0;
begin
  for r in
    select * from massage_bookings
     where transfer_status = 'pending'
       and (date::timestamp + time_slot::interval) < ((now() at time zone 'Asia/Taipei') - interval '5 minutes')
  loop
    update massage_bookings set transfer_status=null, transfer_to_email=null, transfer_to_name=null, transfer_invited_at=null, updated_at=now()
     where booking_id = r.booking_id;
    insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
    values ('massageTransferExpired', 'system', '系統', r.transfer_to_email, r.booking_id, r.date, r.time_slot, '轉讓逾時失效，退回原預約人 ' || r.user_email);
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok', true, 'expired', v_count);
end $function$;


CREATE OR REPLACE FUNCTION public.massage_get_transfers()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select jsonb_build_object(
    'ok', true,
    'incoming', coalesce((
      select jsonb_agg(jsonb_build_object(
        'bookingId', booking_id, 'date', date, 'timeSlot', time_slot,
        'fromEmail', user_email, 'fromName', user_name, 'invitedAt', transfer_invited_at
      ) order by transfer_invited_at)
      from massage_bookings
      where transfer_status = 'pending' and status = 'booked'
        and lower(transfer_to_email) = _ms_jwt_email()
    ), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(jsonb_build_object(
        'bookingId', booking_id, 'date', date, 'timeSlot', time_slot,
        'toEmail', transfer_to_email, 'toName', transfer_to_name, 'invitedAt', transfer_invited_at
      ) order by transfer_invited_at)
      from massage_bookings
      where transfer_status = 'pending' and status = 'booked'
        and lower(user_email) = _ms_jwt_email()
    ), '[]'::jsonb)
  );
$function$;


CREATE OR REPLACE FUNCTION public.massage_offer_transfer(p_booking_id text, p_to_email text, p_to_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := _ms_jwt_email();
  v_row massage_bookings;
  v_diff_hours numeric;
begin
  if p_booking_id is null or p_to_email is null then return jsonb_build_object('ok', false, 'error', '缺少必要參數'); end if;
  select * into v_row from massage_bookings where booking_id = p_booking_id;
  if v_row is null then return jsonb_build_object('ok', false, 'error', '找不到預約'); end if;
  if v_row.user_email <> v_email then return jsonb_build_object('ok', false, 'error', '無權操作他人預約'); end if;
  if v_row.status <> 'booked' then return jsonb_build_object('ok', false, 'error', '預約狀態不可轉讓'); end if;
  if lower(p_to_email) = v_email then return jsonb_build_object('ok', false, 'error', '不能轉讓給自己'); end if;

  v_diff_hours := extract(epoch from ((v_row.date::timestamp + v_row.time_slot::interval) - (now() at time zone 'Asia/Taipei'))) / 3600.0;
  if v_diff_hours < 0.5 then
    return jsonb_build_object('ok', false, 'error', '距離時段不足 30 分鐘，已無法發起轉讓');
  end if;

  if exists (select 1 from massage_waitlist where date = v_row.date and time_slot = v_row.time_slot and status = 'waiting') then
    return jsonb_build_object('ok', false, 'error', '此時段有人候補中，無法轉讓，請改用取消讓候補遞補');
  end if;

  if exists (select 1 from massage_settings where key='violationCounts' and coalesce((value->>lower(p_to_email))::int,0) >= 3) then
    return jsonb_build_object('ok', false, 'error', '該同事帳號已被停用，無法接受轉讓');
  end if;

  update massage_bookings
     set transfer_status='pending', transfer_to_email=lower(p_to_email), transfer_to_name=p_to_name, transfer_invited_at=now(), updated_at=now()
   where booking_id = p_booking_id;

  insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
  values ('massageOfferTransfer', v_email, v_email, lower(p_to_email), p_booking_id, v_row.date, v_row.time_slot, '發起轉讓邀請');
  return jsonb_build_object('ok', true);
end $function$;


CREATE OR REPLACE FUNCTION public.massage_withdraw_transfer(p_booking_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := _ms_jwt_email();
  v_row massage_bookings;
begin
  select * into v_row from massage_bookings where booking_id = p_booking_id;
  if v_row is null then return jsonb_build_object('ok', false, 'error', '找不到預約'); end if;
  if v_row.user_email <> v_email then return jsonb_build_object('ok', false, 'error', '無權操作'); end if;
  if v_row.transfer_status <> 'pending' then return jsonb_build_object('ok', false, 'error', '目前沒有進行中的轉讓邀請'); end if;

  update massage_bookings set transfer_status=null, transfer_to_email=null, transfer_to_name=null, transfer_invited_at=null, updated_at=now()
   where booking_id = p_booking_id;
  insert into massage_log (action, actor_email, actor_name, target_email, booking_id, date, time_slot, detail)
  values ('massageWithdrawTransfer', v_email, v_email, v_email, p_booking_id, v_row.date, v_row.time_slot, '撤回轉讓邀請');
  return jsonb_build_object('ok', true);
end $function$;

-- ─────────────────────────────────────────────
-- 權限：一律收回 public/anon，只給已登入者
-- ─────────────────────────────────────────────
revoke execute on function massage_get_transfers()                      from public, anon;
revoke execute on function massage_offer_transfer(text, text, text)     from public, anon;
revoke execute on function massage_withdraw_transfer(text)              from public, anon;
revoke execute on function massage_accept_transfer(text)                from public, anon;
revoke execute on function massage_decline_transfer(text)               from public, anon;
revoke execute on function massage_expire_transfers()                   from public, anon;

grant  execute on function massage_get_transfers()                      to authenticated;
grant  execute on function massage_offer_transfer(text, text, text)     to authenticated;
grant  execute on function massage_withdraw_transfer(text)              to authenticated;
grant  execute on function massage_accept_transfer(text)                to authenticated;
grant  execute on function massage_decline_transfer(text)               to authenticated;
grant  execute on function massage_expire_transfers()                   to authenticated;

-- 驗證（預期 6 列，auth_exec 全 true、anon_exec 全 false）：
--   select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as auth_exec,
--          has_function_privilege('anon', p.oid, 'execute') as anon_exec
--     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname like 'massage_%transfer%' order by 1;
