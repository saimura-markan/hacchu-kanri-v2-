-- ================================================================
-- E-Li 工事受発注システム — Storage RLS ポリシー
-- Supabase SQL Editor で実行してください
-- ================================================================

-- ----------------------------------------------------------------
-- site-images バケット（現場情報・追記画面の写真）
-- バケット設定: Public ON（getPublicUrl() で表示）
-- ----------------------------------------------------------------

-- アップロード許可（現状: 認証不要 ※要件に応じて見直し推奨）
CREATE POLICY "allow_upload_site_images"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'site-images');

-- 推奨: 認証済みユーザーのみに制限する場合は上記の代わりに↓を使用
-- CREATE POLICY "allow_upload_site_images"
--   ON storage.objects FOR INSERT
--   WITH CHECK (bucket_id = 'site-images' AND auth.role() = 'authenticated');
