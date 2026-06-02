-- ================================================================
-- 2. 新規ユーザー作成時に company_id='MK-A3X9' を自動設定するトリガー
-- ================================================================
-- Supabase ダッシュボード > SQL Editor で実行してください
-- ================================================================

-- ----------------------------------------------------------------
-- 関数: 新規ユーザー登録時に profiles 行を upsert
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user_company_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, company_id)
  VALUES (NEW.id, 'MK-A3X9')
  ON CONFLICT (id) DO UPDATE
    SET company_id = EXCLUDED.company_id
    WHERE profiles.company_id IS NULL;
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------
-- トリガー: auth.users への INSERT 後に実行
-- ----------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_set_default_company_id ON auth.users;

CREATE TRIGGER trg_set_default_company_id
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_company_id();

-- ----------------------------------------------------------------
-- 確認クエリ
-- ----------------------------------------------------------------
-- SELECT trigger_name, event_manipulation, event_object_table
-- FROM information_schema.triggers
-- WHERE trigger_name = 'trg_set_default_company_id';
