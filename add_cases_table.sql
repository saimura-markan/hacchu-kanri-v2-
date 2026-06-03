-- ================================================================
-- E-Li 工事受発注システム — casesテーブル追加・ordersテーブル改修
-- 目的: companies → cases（案件）→ orders（作業日程）の3層構造に移行
--
-- 実行手順:
--   Supabase ダッシュボード > SQL Editor > 新しいクエリ > 貼り付けて実行
-- ================================================================


-- ----------------------------------------------------------------
-- 1. casesテーブル 作成
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cases (
  id          uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id  text        REFERENCES companies(id) ON DELETE SET NULL,
  site_id     uuid        REFERENCES sites(id)     ON DELETE SET NULL,
  case_code   text        UNIQUE NOT NULL,
  case_name   text        NOT NULL DEFAULT '',
  created_at  timestamptz DEFAULT now()
);

COMMENT ON TABLE  cases              IS '案件テーブル。companies → cases → orders の中間層。';
COMMENT ON COLUMN cases.case_code   IS '案件番号（例: KJ-001）。INSERTトリガーで自動採番。';
COMMENT ON COLUMN cases.case_name   IS '案件名（例: 神楽様邸リフォーム）。';


-- ----------------------------------------------------------------
-- 2. case_code 自動採番
--    フォーマット: KJ-001（KJ = 工事の頭文字、3桁ゼロ埋め）
--    ※プレフィックスを変えたい場合は 'KJ-' の部分を書き換えてください
-- ----------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS cases_code_seq START 1;

CREATE OR REPLACE FUNCTION fn_set_case_code()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.case_code IS NULL OR NEW.case_code = '' THEN
    NEW.case_code := 'KJ-' || lpad(nextval('cases_code_seq')::text, 3, '0');
  END IF;
  RETURN NEW;
END;
$$;

-- 既存トリガーがあれば削除してから再作成
DROP TRIGGER IF EXISTS trg_cases_set_code ON cases;
CREATE TRIGGER trg_cases_set_code
  BEFORE INSERT ON cases
  FOR EACH ROW EXECUTE FUNCTION fn_set_case_code();


-- ----------------------------------------------------------------
-- 3. ordersテーブルに case_id カラムを追加
--    既存レコードは case_id = NULL のまま残る（後でバッチ移行可）
-- ----------------------------------------------------------------
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS case_id uuid REFERENCES cases(id) ON DELETE SET NULL;


-- ----------------------------------------------------------------
-- 4. インデックス（検索・JOIN高速化）
-- ----------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_cases_company_id ON cases(company_id);
CREATE INDEX IF NOT EXISTS idx_cases_site_id    ON cases(site_id);
CREATE INDEX IF NOT EXISTS idx_orders_case_id   ON orders(case_id);


-- ----------------------------------------------------------------
-- 5. RLS（Row Level Security）
-- ----------------------------------------------------------------
ALTER TABLE cases ENABLE ROW LEVEL SECURITY;

-- 既存ポリシーがあれば削除（冪等に実行できるよう）
DROP POLICY IF EXISTS "cases_admin_manager_all"  ON cases;
DROP POLICY IF EXISTS "cases_staff_select"        ON cases;
DROP POLICY IF EXISTS "cases_user_select"         ON cases;
DROP POLICY IF EXISTS "cases_user_insert"         ON cases;

-- admin / manager: 全件 CRUD
CREATE POLICY "cases_admin_manager_all"
  ON cases FOR ALL TO authenticated
  USING (
    (auth.jwt() -> 'user_metadata' ->> 'role') IN ('admin', 'manager')
  )
  WITH CHECK (
    (auth.jwt() -> 'user_metadata' ->> 'role') IN ('admin', 'manager')
  );

-- staff: 全件 SELECT のみ（管理者画面で一覧表示するため）
CREATE POLICY "cases_staff_select"
  ON cases FOR SELECT TO authenticated
  USING (
    (auth.jwt() -> 'user_metadata' ->> 'role') = 'staff'
  );

-- user: 自社の案件のみ SELECT
CREATE POLICY "cases_user_select"
  ON cases FOR SELECT TO authenticated
  USING (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
  );


-- ----------------------------------------------------------------
-- 6. 動作確認クエリ（実行後にコメントを外して確認）
-- ----------------------------------------------------------------
-- テーブル存在確認
-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public' AND table_name = 'cases';

-- casesテスト挿入（case_codeが自動採番されること）
-- INSERT INTO cases (company_id, case_name)
-- VALUES ('MK-TEST', '動作確認案件')
-- RETURNING id, case_code, case_name, created_at;

-- ordersのcase_idカラム確認
-- SELECT column_name, data_type, is_nullable
-- FROM information_schema.columns
-- WHERE table_name = 'orders' AND column_name = 'case_id';

-- RLSポリシー確認
-- SELECT policyname, cmd, qual
-- FROM pg_policies
-- WHERE tablename = 'cases'
-- ORDER BY cmd;
