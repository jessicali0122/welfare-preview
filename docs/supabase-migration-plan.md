# 午茶模組 Supabase 遷移規劃

> 目標:解決午茶（High Tea）存檔慢／異常，並上線逐列即時協作。
> 範圍:**只搬午茶模組**（events / items / vendors）。報銷、投票、回饋、使用者驗證等**繼續留在 GAS**,兩邊並存。
> 驗證策略:**維持現有 GAS 登入**（前端拿 GAS 發的 token 換 Supabase 存取權），登入 UX 不變。
> 資料庫:Supabase（PostgreSQL）。前端仍是 GitHub Pages 上的 `index.html`。

---

## 0. 為什麼是 Supabase 不是 Firebase

- 現有資料是「表格 + 列」（Google Sheet）→ 對應 Postgres 幾乎一對一,搬遷成本低。
- 專案大量做彙總報表（總預算、實際支出、廠商訂購次數、月份統計）→ SQL 的 `sum()`/`group by`/view 一句搞定;Firestore NoSQL 做複雜彙總很痛。
- 即時協作兩者都有,但 Supabase Realtime「訂閱一張表的變動」對逐列協作最直接。
- Firebase 只有在「即時聊天、大量行動 App 推播、深綁 Google 生態」時才更合 —— 本專案不是。

---

## 1. 現有痛點（診斷結論）

- 主存檔路徑 `htUpsertItems` 已優化良好（單鎖、只寫變動列、主路徑已移除 TextFinder）。
- **殘留慢點**:`htUpdateVendor` → `htFindRow` 仍用 `createTextFinder`（每次 1~3 秒）。
  存檔時每筆「已訂購」狀態變動的品項都會呼叫一次 → 一次勾多筆訂購再存 = 爆慢。
- **先天天花板**:GAS Web App 每次 `doPost` 有冷啟動 + 排程延遲,單次常 1~2 秒起跳,優化消不掉。
- → Supabase 直連 PostgREST 單次約 50~150ms,才是「按了就好」的解法。

---

## 2. 資料表設計（對照現有 3 張分頁）

### `ht_events`(對應 `hightea` 分頁 17 欄)
```sql
create table ht_events (
  event_id      text primary key,          -- HT-2026-08
  month         text not null,             -- 2026-08
  event_date    date,
  headcount     int  default 0,
  budget_pp     int  default 0,
  budget_total  int  default 0,
  actual_exp    numeric default 0,         -- 由 view/trigger 維護,不再由前端算
  birthday_exp  numeric default 0,
  status        text default 'draft',
  birthdays     jsonb default '[]',        -- 壽星清單
  notes         text,
  reimburse_ref text,                       -- 報銷案件
  organizer1    text,
  organizer2    text,
  created_by    text,
  created_at    timestamptz default now(),
  completed_at  timestamptz,
  updated_at    timestamptz default now()
);
```

### `ht_items`(對應 `hightea_items` 18 欄)
```sql
create table ht_items (
  item_id      text primary key,           -- ITM-uuid
  event_id     text references ht_events(event_id) on delete cascade,
  name         text,
  vendor       text,
  category     text default '其他',
  unit_price   numeric default 0,
  qty          int default 0,
  subtotal     numeric generated always as (unit_price * qty) stored,  -- 小計自動算
  serving      text,
  assignee     text,
  ordered      boolean default false,
  ordered_at   timestamptz,
  notes        text,
  rating_sum   int default 0,
  rating_count int default 0,
  avg_rating   numeric default 0,
  link         text,
  sort_order   int default 0,
  updated_at   timestamptz default now()
);
create index on ht_items(event_id);
```

### `ht_vendors`(對應 `hightea_vendors` 8 欄)
```sql
create table ht_vendors (
  name          text primary key,
  category      text,
  total_orders  int default 0,
  rating_sum    int default 0,
  rating_count  int default 0,
  avg_rating    numeric default 0,
  last_used     text,
  tags          text
);
```

### 彙總改由 DB 維護(取代 htRecalcExpense / htUpdateVendor 的 TextFinder）

實際支出改用 view（或在 `ht_items` 上加 trigger 回寫 `ht_events.actual_exp`）:
```sql
create or replace view ht_event_expense as
select event_id, coalesce(sum(subtotal),0) as actual_exp
from ht_items group by event_id;
```
廠商訂購次數同理,用 trigger 在 `ordered` 變動時 +/-1,不再逐筆 TextFinder。

---

## 3. 前端改動（最小化）

前端已有 `htApi(action, data)` 抽象層。只改這一個函式內部:午茶 action 轉打 Supabase,其餘仍走 GAS。

```js
const HT_SUPABASE_ACTIONS = new Set([
  'htList','htGetItems','htCreate','htUpdate','htDeleteEvent',
  'htSaveItems','htUpsertItem','htUpsertItems','htDeleteItem','htReorderItems'
]);

async function htApi(action, data) {
  if (HT_SUPABASE_ACTIONS.has(action)) return htSupabase(action, data); // 新:午茶走 Supabase
  return htGasApi(action, data);                                        // 舊:其他仍走 GAS
}
```

- UI 元件、渲染、dirty 佇列、樂觀更新邏輯 **幾乎不動**。
- 存單列 = 一句 `upsert`（約 50~150ms）取代 GAS 的 1~3 秒。

---

## 4. 驗證(維持 GAS 登入 + RLS）

- 登入仍走 GAS，前端持有 GAS 發的 token。
- 前端用 Supabase **anon key**（放公開前端是正常做法,靠 RLS 保護）連線。
- RLS 策略:午茶 3 張表僅「已驗證使用者」可讀寫。
- 銜接方式(二選一,實作階段決定):
  1. **簡單版**:前端先呼叫 GAS 驗 token → 通過才用 anon key 存取;RLS 用寬鬆的「anon 可讀寫午茶表」+ 前端 gate。
  2. **嚴謹版**:GAS 驗完 token 後簽發一個 Supabase 相容 JWT（`custom access token`），RLS 依 JWT claim 控權。
- 內部工具建議先用簡單版,之後要收緊再上嚴謹版。

---

## 5. 即時協作(逐列同步）

```js
supabase.channel('ht-' + eventId)
  .on('postgres_changes',
      { event: '*', schema: 'public', table: 'ht_items', filter: 'event_id=eq.' + eventId },
      payload => applyRemoteChange(payload))   // 別人改哪列,畫面即時更新
  .subscribe();
```
搭配現有逐列 dirty 佇列架構即可,前端本來就是這個模型。

---

## 6. 執行步驟與工時

| 階段 | 內容 | 估時 |
|---|---|---|
| 0 | 建 Supabase 專案、建 3 張表 + view/trigger + RLS | 0.5 天 |
| 1 | 匯出 3 張 Sheet → 匯入 Supabase（一次性搬歷史資料） | 0.5 天 |
| 2 | 改 `htApi` shim + 午茶各 action 對接 PostgREST | 1~2 天 |
| 3 | 接 Realtime 即時協作 | 0.5 天 |
| 4 | 影子測試 → 切換 → 保留 GAS 當 rollback | 0.5 天 |

**合計約 3~4 個工作天**,可分批上線,不需停機。

---

## 7. 成本

- 免費額度內即可（DB 500MB / 每月 5 萬 MAU / Realtime 免費）。
- 內部工具規模遠低於門檻,**實務上一毛不用付**。

---

## 8. 切換與回滾（Rollback）

- 階段 2~3 期間可「雙寫」（同時寫 Supabase 與 GAS）做影子比對。
- 正式切換 = `HT_SUPABASE_ACTIONS` 開關開啟;出問題把開關關掉即回退 GAS。
- 保留 GAS 後端與資料至少一個週期,確認穩定再淘汰午茶分頁寫入。

---

## 9. 待決 / 注意事項

- anon key 會出現在公開前端 → 一定要設好 RLS，否則資料裸奔。
- 歷史資料型別:Sheet 內的日期/布林/數字匯入時要清洗（例如 `已訂購` 的 TRUE/1/true 混用）。
- `birthdays` 壽星清單目前在 Sheet 是文字,匯入時轉成 jsonb 陣列。
- 舊「唯讀串接」的歷史試算表（`ht-sheet-history.gs`, `HT_SHEET_ID`）是另一份外部 Sheet,本次不搬,維持唯讀。
