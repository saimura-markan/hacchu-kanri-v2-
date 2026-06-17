-- 株式会社小さな瓦（MK-49E7）に紐づく現場データを削除
-- Supabase SQL Editor で実行してください
-- ⚠️ 実行前に必ず SELECT で対象件数を確認してください

-- ① 削除対象の確認（先にこちらを実行）
SELECT id, site_name, address, created_at
FROM sites
WHERE company_id = 'MK-49E7'
ORDER BY created_at;

-- ② 上記で対象を確認してから削除を実行
DELETE FROM sites
WHERE company_id = 'MK-49E7';
