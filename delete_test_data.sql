-- テストデータ一括削除
-- 対象会社：MK-EW8S（株式会社テスト）/ MK-LDST（株式会社金色ゴリラ）/ MK-49E7（株式会社小さな瓦）
-- Supabase SQL Editor で実行してください
-- ⚠️ 必ずSTEP 1で件数を確認してからSTEP 2・3を実行してください

-- ================================================================
-- STEP 1: 削除対象の確認（先にこちらを実行）
-- ================================================================

-- 各社のsites件数
SELECT company_id, COUNT(*) AS site_count
FROM sites
WHERE company_id IN ('MK-EW8S', 'MK-LDST', 'MK-49E7')
GROUP BY company_id;

-- 各社のorders件数
SELECT company_id, COUNT(*) AS order_count
FROM orders
WHERE company_id IN ('MK-EW8S', 'MK-LDST', 'MK-49E7')
GROUP BY company_id;

-- 各社のprofiles件数
SELECT company_id, COUNT(*) AS profile_count
FROM profiles
WHERE company_id IN ('MK-EW8S', 'MK-LDST', 'MK-49E7')
GROUP BY company_id;

-- ================================================================
-- STEP 2: sitesを削除（MK-49E7は削除済みのため影響なし）
-- ================================================================

DELETE FROM sites
WHERE company_id IN ('MK-EW8S', 'MK-LDST', 'MK-49E7');

-- ================================================================
-- STEP 3: companiesを削除
-- ================================================================

DELETE FROM companies
WHERE id IN ('MK-EW8S', 'MK-LDST', 'MK-49E7');
