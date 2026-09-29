-- ============================================================
-- 按摩：allBookings 不再把「其他人的姓名」回給一般員工（2026-09-24 驗收時發現）
-- 員工畫面只用 allBookings 算各時段已訂名額；姓名只有管理區需要，而管理區讀的是 adminBookings（本來就限管理者）。
-- 做法：取線上現有定義，只把 allBookings 的 'userName' 改成「管理者才給」，其餘一字不動。
-- 比對不到或不只一處 → 直接中止，不改任何東西。idempotent：已改過就略過。
-- ============================================================
do $$
declare
  def text := pg_get_functiondef('massage_get_data()'::regprocedure);
  old text := $x$select jsonb_agg(jsonb_build_object('userName', user_name, 'date', date, 'timeSlot', time_slot, 'status', status))$x$;
  new text := $x$select jsonb_agg(jsonb_build_object('userName', case when v_is_admin then user_name end, 'date', date, 'timeSlot', time_slot, 'status', status))$x$;
  n int;
begin
  if position(new in def) > 0 then
    raise notice '已是新版，略過';
    return;
  end if;
  n := (length(def) - length(replace(def, old, ''))) / length(old);
  if n <> 1 then
    raise exception '預期剛好 1 處，實際 % 處 → 中止，未修改', n;
  end if;
  execute replace(def, old, new);
end $$;

-- 驗證：應為 true（新版已生效）
select position('case when v_is_admin then user_name end' in pg_get_functiondef('massage_get_data()'::regprocedure)) > 0 as patched;
