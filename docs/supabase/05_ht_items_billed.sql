-- 午茶品項「請款」欄位（前端 htToggleBilled / ht-supabase.js 的 billed 對應）
-- 品項讀寫已改走 Supabase，但 ht_items 少了這欄 → 切了請款存不住、會被拉回的資料蓋回否。
-- 已存在時不會有任何影響，可重複執行。
alter table public.ht_items
  add column if not exists billed boolean not null default false;
