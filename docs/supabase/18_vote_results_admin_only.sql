-- ============================================================
-- 午茶日投票 — Migration 18：投票結果只開放福委／管理者
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 問題：ht_vote_get 原本把完整 votes（sat／favs／comment）回給「任何已登入者」，
--       沒有任何角色判斷（同檔的 ht_vote_close 就有 _ht_is_admin() 把關，這支漏了）。
--       → 一般員工只要打開瀏覽器主控台呼叫一次，就讀得到全部人的分數與留言。
--       光把前端結果卡藏起來沒有用，必須從後端擋。
--
-- 修正：votes 只在 _ht_is_admin() 為真時回傳；其餘一律回空陣列。
--       voted／closed 仍要回（前端要據此判斷「我投過了沒」「投票結束了沒」），
--       這兩個值只反映呼叫者自己的狀態，不會洩漏別人的內容。
--       另外新增 canSeeResults，讓前端據此決定要不要畫結果卡，
--       而不是靠前端自己的角色判斷去猜（前端角色只是 UI 收斂，不是權威）。
-- ============================================================

create or replace function ht_vote_get(p_event_id text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := _ht_jwt_email();
  v_votes jsonb := '[]'::jsonb;
  v_voted boolean := false;
  v_admin boolean := _ht_is_admin();
begin
  -- ★ 只有福委／管理者拿得到票的內容
  if v_admin then
    select coalesce(jsonb_agg(jsonb_build_object('sat', sat, 'favs', favs, 'comment', comment)), '[]'::jsonb)
      into v_votes from ht_votes where event_id = p_event_id;
  end if;

  -- 「我自己投過了沒」：只查呼叫者本人的那一筆，不涉及他人資料
  if v_email <> '' then
    select exists (select 1 from ht_votes where event_id = p_event_id and vote_key = _ht_vote_key(v_email, p_event_id))
      into v_voted;
  end if;

  return jsonb_build_object(
    'ok', true,
    'votes', v_votes,
    'voted', v_voted,
    'canSeeResults', v_admin,
    'closed', coalesce((select closed from ht_vote_config where event_id = p_event_id), false)
  );
end $$;
revoke execute on function ht_vote_get(text) from public;
revoke execute on function ht_vote_get(text) from anon;
grant  execute on function ht_vote_get(text) to   authenticated;

-- ─────────────────────────────────────────────
-- 驗證用（選跑）
-- ─────────────────────────────────────────────
-- 以「一般員工」身分呼叫，votes 應為 []、canSeeResults 應為 false：
--   select set_config('request.jwt.claims',
--     json_build_object('role','authenticated','email','<某位一般員工>','app_roles',json_build_array('employee'))::text, true);
--   select ht_vote_get('HTD-2026-09-18');
-- 以福委身分呼叫，votes 應拿得到內容、canSeeResults 為 true：
--   select set_config('request.jwt.claims',
--     json_build_object('role','authenticated','email','<福委>','app_roles',json_build_array('employee','welfare'))::text, true);
--   select ht_vote_get('HTD-2026-09-18');
