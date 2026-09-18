-- ============================================================
-- 按摩預約 — Migration 17：同事互轉預約「前端 UI 上線」所需的兩件事
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 背景：轉讓的 5 支 RPC（offer/withdraw/accept/decline/expire）先前已建在 DB，
-- 但少了兩塊拼圖，所以功能形同不存在：
--   (1) 沒有任何 RPC 會告訴「被轉讓的人」有邀請 → 前端畫不出收件匣。
--   (2) massage_expire_transfers() 沒有任何排程在呼叫 → 逾時邀請永遠不會退回。
-- 本檔補上這兩塊。刻意不改動已在線上運作的 massage_get_data()，避免動到核心讀取。
-- ============================================================

-- ─────────────────────────────────────────────
-- 1) massage_get_transfers — 轉讓邀請查詢（前端收件匣用）
--    incoming：別人要轉給我、還沒回應的
--    outgoing：我發出去、對方還沒接受的
--    可見範圍由 JWT 的 email 決定，不吃任何前端參數 → 看不到別人的邀請。
-- ─────────────────────────────────────────────
create or replace function massage_get_transfers() returns jsonb
  language sql stable security definer set search_path = public, extensions as $$
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
$$;
revoke execute on function massage_get_transfers() from public;
revoke execute on function massage_get_transfers() from anon;
grant  execute on function massage_get_transfers() to authenticated;

-- ─────────────────────────────────────────────
-- 2) 逾時邀請自動退回：改用 Supabase 自己的 pg_cron，不接 GAS 觸發器
--    理由：按摩已全面改成「前端直連 Supabase」，再拉一支 GAS 觸發器回來
--    會讓這個功能重新依賴 Google（版本上限、間歇安全牆）。
--    pg_cron 在 DB 內執行，與前端／GAS 完全無關。
-- ─────────────────────────────────────────────
create extension if not exists pg_cron;

select cron.unschedule('massage-expire-transfers')
  where exists (select 1 from cron.job where jobname = 'massage-expire-transfers');

select cron.schedule('massage-expire-transfers', '*/5 * * * *',
  $job$ select massage_expire_transfers() $job$);

-- ─────────────────────────────────────────────
-- 3) 驗證用（選跑）
-- ─────────────────────────────────────────────
-- 排程有沒有掛上（預期 1 列、active=true）：
--   select jobid, jobname, schedule, active from cron.job where jobname='massage-expire-transfers';
-- 排程執行紀錄（跑過幾次、有沒有失敗）：
--   select status, return_message, start_time from cron.job_run_details
--    where jobid=(select jobid from cron.job where jobname='massage-expire-transfers')
--    order by start_time desc limit 10;
-- 目前身分看得到的邀請（預期只有自己的）：
--   select massage_get_transfers();
-- 5 支轉讓 RPC 的權限（預期 authenticated=true、anon=false）：
--   select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as auth_exec,
--          has_function_privilege('anon', p.oid, 'execute') as anon_exec
--     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname like '%transfer%' order by 1;
