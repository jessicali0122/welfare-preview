-- 午茶活動自訂名稱：活動設定裡可填「活動名稱」，沒填就顯示「午茶日」
-- 已存在時不會有任何影響，可重複執行。
alter table public.ht_events
  add column if not exists title text;
