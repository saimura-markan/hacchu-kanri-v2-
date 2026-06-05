-- ================================================================
-- トリガー修正: ハードコードされた company_id='MK-A3X9' を除去
-- ================================================================
-- 問題: 新規ユーザー登録時にトリガーが company_id='MK-A3X9' で
--       profiles 行を先に作成するため、handleRegister の insert が
--       重複エラーで失敗し正しい company_id が保存されなかった。
-- 修正: トリガーは company_id を設定せず空の行だけを作成する。
--       handleRegister 側で upsert により正しい company_id を上書きする。
-- ================================================================
-- Supabase ダッシュボード > SQL Editor で実行してください
-- ================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user_company_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;
