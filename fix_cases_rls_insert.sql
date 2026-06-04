-- ================================================================
-- E-Li — cases テーブル INSERT ポリシー追加
-- 原因: お客様ユーザー（role=user）の INSERT ポリシーが未定義だった
-- ================================================================

-- 既存ポリシーがあれば削除（冪等実行）
DROP POLICY IF EXISTS "cases_user_insert" ON cases;

-- お客様ユーザー: 自社の案件のみ INSERT 可
--   company_id が自分の会社と一致する、または null（会社未設定ユーザー）
CREATE POLICY "cases_user_insert"
  ON cases FOR INSERT TO authenticated
  WITH CHECK (
    company_id IS NULL
    OR company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
  );
