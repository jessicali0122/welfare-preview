-- ============================================================
-- 案件鏡像「刪除案件後跟著清鏡像」— Migration 10（Stage 3/4 收尾）
-- 在 Supabase → SQL Editor 貼上整段執行即可（idempotent，可重複執行）。
-- ------------------------------------------------------------
-- 背景：deleteCase 只能刪「草稿」（管理者操作，非草稿一律改用作廢以保留稽核）。
--       刪除後試算表那列真的沒了，但 cases_mirror / case_detail_mirror 原本設計
--       是「只 upsert 不刪除」（避免暫時抓不到資料就整批清空），導致已刪除的草稿
--       殘留在鏡像裡——理論上只有申請人自己看得到、風險低，但不乾淨，這裡補上。
--
-- 做法：每次同步時，把「這次收到的完整案件清單」當作唯一真相，
--       鏡像裡任何不在這份清單內的舊列，視為已被刪除 → 一併清掉。
-- 安全閘門（重要）：只有在這份清單「非空」時才清理；若清單是空的（例如 GAS 端
--       listCases 剛好失敗、或呼叫端沒帶齊），一律不清除，避免誤刪整表。
-- ============================================================

-- ─────────────────────────────────────────────
-- A) cases_sync：p_cases 本身就是「目前全部案件」的完整快照 → 直接拿它的 case_id 集合當基準
-- ─────────────────────────────────────────────
create or replace function cases_sync(p_cases jsonb) returns jsonb
  language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0;
declare deleted_n int := 0;
declare valid_ids text[];
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_cases is null or jsonb_typeof(p_cases) <> 'array' then
    return jsonb_build_object('ok', false, 'error', '缺少案件資料');
  end if;

  insert into cases_mirror (case_id, applicant_email, chain_emails, status, data, synced_at)
  select c ->> 'caseId',
         lower(coalesce(c ->> 'email', '')),
         coalesce(
           (select array_agg(lower(x))
              from jsonb_array_elements_text(
                     case when jsonb_typeof(c -> 'chainEmails') = 'array'
                          then c -> 'chainEmails' else '[]'::jsonb end) as x
             where coalesce(x, '') <> ''),
           '{}'
         ),
         c ->> 'status',
         c,
         now()
    from jsonb_array_elements(p_cases) as c
   where coalesce(c ->> 'caseId', '') <> ''
  on conflict (case_id) do update
     set applicant_email = excluded.applicant_email,
         chain_emails    = excluded.chain_emails,
         status          = excluded.status,
         data            = excluded.data,
         synced_at       = now();

  get diagnostics n = row_count;

  -- ★ 清理：把不在這次「完整清單」內的舊列刪掉（＝已從試算表刪除的草稿）。
  --   閘門：清單非空才清（避免呼叫端異常給空陣列時誤刪整表）。
  select array_agg(c ->> 'caseId') into valid_ids
    from jsonb_array_elements(p_cases) as c
   where coalesce(c ->> 'caseId', '') <> '';

  if valid_ids is not null and array_length(valid_ids, 1) > 0 then
    delete from cases_mirror where case_id <> all (valid_ids);
    get diagnostics deleted_n = row_count;
  end if;

  return jsonb_build_object('ok', true, 'synced', n, 'deleted', deleted_n,
                            'total', (select count(*) from cases_mirror));
end $$;
revoke execute on function cases_sync(jsonb) from public;
revoke execute on function cases_sync(jsonb) from anon;
grant  execute on function cases_sync(jsonb) to   authenticated;   -- 實際仍由 _ht_is_admin() 內部再擋一層

-- ─────────────────────────────────────────────
-- B) case_detail_sync：p_details 可能因單張 getCase 暫時失敗而「跳過」，不能拿它當完整清單
--    （否則會誤刪『這次剛好抓失敗、但其實還在』的詳情）。改由呼叫端另外帶入
--    p_valid_ids（同一批的完整 caseId 清單，來源與 cases_sync 那批相同），只清「真的不在裡面」的列。
--    ★ 多一個參數＝在 Postgres 裡是不同函式簽名，不是「取代」，故先明確砍掉舊的單參數版本。
-- ─────────────────────────────────────────────
drop function if exists case_detail_sync(jsonb);

create or replace function case_detail_sync(p_details jsonb, p_valid_ids jsonb default null) returns jsonb
  language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0;
declare deleted_n int := 0;
declare valid_ids text[];
begin
  if not _ht_is_admin() then return jsonb_build_object('ok', false, 'error', '限福委／管理者使用'); end if;
  if p_details is null or jsonb_typeof(p_details) <> 'array' then
    return jsonb_build_object('ok', false, 'error', '缺少詳情資料');
  end if;

  insert into case_detail_mirror (case_id, applicant_email, chain_emails, data, synced_at)
  select d ->> 'case_id',
         lower(coalesce(d ->> 'applicant_email', '')),
         coalesce(
           (select array_agg(lower(x))
              from jsonb_array_elements_text(
                     case when jsonb_typeof(d -> 'chain_emails') = 'array'
                          then d -> 'chain_emails' else '[]'::jsonb end) as x
             where coalesce(x, '') <> ''),
           '{}'
         ),
         d -> 'data',
         now()
    from jsonb_array_elements(p_details) as d
   where coalesce(d ->> 'case_id', '') <> ''
     and jsonb_typeof(d -> 'data') = 'object'
  on conflict (case_id) do update
     set applicant_email = excluded.applicant_email,
         chain_emails    = excluded.chain_emails,
         data            = excluded.data,
         synced_at       = now();

  get diagnostics n = row_count;

  -- ★ 清理：用「完整 caseId 清單」(p_valid_ids，來自同一批 listCases 結果) 為準，
  --   不是用 p_details（詳情可能因單張暫時失敗而缺漏，不能當完整清單，否則會誤刪）。
  --   閘門：p_valid_ids 非空才清。
  if p_valid_ids is not null and jsonb_typeof(p_valid_ids) = 'array' then
    select array_agg(x) into valid_ids
      from jsonb_array_elements_text(p_valid_ids) as x
     where coalesce(x, '') <> '';
  end if;

  if valid_ids is not null and array_length(valid_ids, 1) > 0 then
    delete from case_detail_mirror where case_id <> all (valid_ids);
    get diagnostics deleted_n = row_count;
  end if;

  return jsonb_build_object('ok', true, 'synced', n, 'deleted', deleted_n,
                            'total', (select count(*) from case_detail_mirror));
end $$;
revoke execute on function case_detail_sync(jsonb, jsonb) from public;
revoke execute on function case_detail_sync(jsonb, jsonb) from anon;
grant  execute on function case_detail_sync(jsonb, jsonb) to   authenticated;

-- ─────────────────────────────────────────────
-- C) 驗證用（選跑）
-- ─────────────────────────────────────────────
--   select count(*) from cases_mirror;
--   select count(*) from case_detail_mirror;
