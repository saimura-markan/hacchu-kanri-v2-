-- ================================================================
-- E-Li 工事受発注システム — 顧客メール通知（A案：即時送信）
--   第1段階：「日程確定」1イベントのみ
--
--   構成:
--     public.orders の AFTER UPDATE トリガー
--       → pg_net で Edge Function `send-order-notification` を POST
--       → Edge Function が orders → auth.users で宛先を解決して Resend 送信
--
--   ★ index.html には一切手を入れない。クライアント側は無変更。
--
--   ★ 実行順序:
--     1. Edge Function `send-order-notification` を先にデプロイし、
--        Secrets（ELI_NOTIFY_SECRET / APP_URL）を設定しておくこと。
--        このSQLだけ先に流すと、トリガーは 401 を受け取り続ける。
--     2. STEP 0 の事前確認を実行して結果を確かめる。
--     3. STEP 1 以降を実行する。
--
--   ★ このリポジトリは public。
--     STEP 3 のシークレット実値をファイルに書き戻してコミットしないこと。
--     SQL Editor 上でだけ実値に置き換えて実行する。
--
--   使い方:
--     cat add_email_notification_schedule_fixed.sql | pbcopy
--     → Supabase ダッシュボード > SQL Editor
-- ================================================================


-- ================================================================
-- STEP 0 : 事前確認（★ここだけ先に実行して結果を確認する）
-- ================================================================

-- 0-1. orders.id の型を確認する。
--   リポジトリ内の定義が食い違っているため実体で確定させる。
--     add_status_logs_table.sql:8      → order_id text
--     add_schedule_history.sql:12      → order_id text
--     add_order_change_logs.sql:9      → order_id text
--     order_images_table.sql:11        → order_id uuid REFERENCES orders(id)  ← 食い違い
--   CLAUDE.md:133 の例が id:"B-2024-101" なので text の可能性が高いが、
--   下のトリガー関数は NEW.id::text で送るためどちらでも動く。記録のため確認する。
SELECT column_name, data_type
FROM   information_schema.columns
WHERE  table_schema = 'public' AND table_name = 'orders'
   AND column_name IN ('id','user_id','status','deleted_at')
ORDER  BY column_name;

-- 0-2. pg_net が使えるか確認する。
SELECT extname, extversion, nspname AS schema
FROM   pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE  extname = 'pg_net';
--   → 0行なら STEP 1 で有効化する。

-- 0-3. Vault が使えるか確認する。
SELECT extname FROM pg_extension WHERE extname = 'supabase_vault';


-- ================================================================
-- STEP 1 : pg_net の有効化
-- ================================================================
--   Supabase では既定でインストール済みだが未有効の場合がある。
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;


-- ================================================================
-- STEP 2 : 送信ログテーブル
-- ================================================================
--   目的:
--     ・実際に送られたか／なぜ送られなかったかを DB 側で追える唯一の記録。
--       Resend ダッシュボードには「送らなかった理由」が残らない。
--     ・将来 §12 の「未読のときだけ送信」に切り替える際の実績データになる。
--
--   命名: profiles.eli_notification_excluded と同じ規約に従い eli_ 接頭辞。
--         profiles は E-Li / MK Daily / Seed Note の3システム共有だが、
--         本テーブルは E-Li 専用。他システムからは参照しない。
--
--   ★ 宛先メールアドレスそのものは保存しない（@以降のドメインのみ）。
--     ログテーブルが顧客メールアドレスの二次的な保管場所になるのを避ける。
CREATE TABLE IF NOT EXISTS public.eli_email_log (
  id         bigserial   PRIMARY KEY,
  order_id   text,
  event      text        NOT NULL,
  result     text        NOT NULL CHECK (result IN ('sent','skipped','error')),
  detail     text,
  to_domain  text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_eli_email_log_created
  ON public.eli_email_log (created_at DESC);

COMMENT ON TABLE public.eli_email_log IS
  'E-Li 顧客メール通知の送信ログ。Edge Function send-order-notification が書く。'
  '宛先はドメインのみ保存する（メールアドレス本体は保存しない）。';

ALTER TABLE public.eli_email_log ENABLE ROW LEVEL SECURITY;

--   service_role は RLS をバイパスするため Edge Function 用のポリシーは不要。
--   閲覧のみ admin / manager に開ける。
DROP POLICY IF EXISTS "admins_read_eli_email_log" ON public.eli_email_log;
CREATE POLICY "admins_read_eli_email_log"
  ON public.eli_email_log FOR SELECT
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin','manager'));

REVOKE ALL ON public.eli_email_log FROM PUBLIC, anon;
GRANT SELECT ON public.eli_email_log TO authenticated;


-- ================================================================
-- STEP 3 : Vault にシークレットを保存
-- ================================================================
--   ★ 下の 2 か所を SQL Editor 上で実値に置き換えてから実行する。
--     置き換えた状態のファイルをコミットしないこと（このリポジトリは public）。
--
--   ELI_NOTIFY_SECRET は Edge Function の Secrets に設定した値と
--   完全に同一でなければならない。生成:  openssl rand -hex 32
--
--   ※ 関数URL自体は秘密ではない（SUPABASE_URL は index.html:310 に平文で
--     あり公開済み）。それでも環境依存値なので Vault にまとめて置く。

-- 3-1. 共有シークレット
SELECT vault.create_secret(
  '【ここに ELI_NOTIFY_SECRET と同じ64桁の値】',
  'eli_notify_secret',
  'E-Li 顧客メール通知 Edge Function の共有シークレット'
);

-- 3-2. Edge Function の URL
SELECT vault.create_secret(
  'https://wxjmqrxaqrujsvgzknwy.supabase.co/functions/v1/send-order-notification',
  'eli_notify_url',
  'E-Li 顧客メール通知 Edge Function のエンドポイント'
);

--   やり直す場合（既存を消してから再登録する）:
--     DELETE FROM vault.secrets WHERE name IN ('eli_notify_secret','eli_notify_url');


-- ================================================================
-- STEP 4 : トリガー関数
-- ================================================================
--   ★ 設計上の要点
--
--   (1) この関数は絶対に UPDATE を失敗させない。
--       Vault が読めない・pg_net が無い・URLが空 —— どの異常でも
--       WARNING を出して NEW を返すだけにする。メール通知は付加機能であり、
--       日程確定という業務操作を巻き込んで失敗させてはならない（計画書 §12-2）。
--
--   (2) net.http_post は非同期。リクエストをキューに積んで即座に戻り、
--       実際の送信は background worker がトランザクション後に行う。
--       したがって UPDATE の応答時間には実質的に影響しない（同 §12-1）。
--
--   (3) 送るのは order_id と event だけ。宛先も案件情報も渡さない。
--       宛先解決は Edge Function 側で orders → auth.users と辿る。
--
--   (4) SECURITY DEFINER。vault.decrypted_secrets は postgres 以外読めないため。
CREATE OR REPLACE FUNCTION public.eli_notify_schedule_fixed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, vault, pg_temp
AS $$
DECLARE
  v_url    text;
  v_secret text;
BEGIN
  SELECT decrypted_secret INTO v_url
  FROM   vault.decrypted_secrets WHERE name = 'eli_notify_url';

  SELECT decrypted_secret INTO v_secret
  FROM   vault.decrypted_secrets WHERE name = 'eli_notify_secret';

  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE WARNING '[eli_notify] vault secret missing; skipped order %', NEW.id;
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url     := v_url,
    body    := jsonb_build_object(
                 'event',    'schedule_fixed',
                 'order_id', NEW.id::text
               ),
    headers := jsonb_build_object(
                 'Content-Type',        'application/json',
                 'x-eli-notify-secret', v_secret
               ),
    timeout_milliseconds := 5000
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- ★ 何があっても UPDATE 本体は成功させる。
  RAISE WARNING '[eli_notify] order %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.eli_notify_schedule_fixed() IS
  'orders.status が 日程確定 に変わったとき Edge Function send-order-notification を'
  '非同期に叩く。失敗しても UPDATE は成功させる。E-Li 専用。';

--   ★ anon の剥奪は「FROM PUBLIC, anon」と明示する。
--     Supabase の ALTER DEFAULT PRIVILEGES が public スキーマの関数に
--     anon への EXECUTE を明示付与するため、FROM PUBLIC だけでは剥がれない
--     （2026-07-29 fix_rpc_anon_grants.sql で確認済みの挙動）。
REVOKE ALL ON FUNCTION public.eli_notify_schedule_fixed()
  FROM PUBLIC, anon, authenticated;


-- ================================================================
-- STEP 5 : トリガー
-- ================================================================
--   AFTER UPDATE OF status … status が SET 句に含まれるときだけ評価する。
--   WHEN 句で以下に絞る:
--     ・status が実際に変化した（同値更新では発火しない）
--     ・新しい値が 日程確定
--     ・論理削除されていない
--
--   ★ これで A/B/C の3経路（index.html:10490 handleStatusChange /
--     :10570 編集モーダル保存 / :10681 handleRescheduleConfirm）すべてを
--     1箇所でカバーする。クライアントには1行も足さない。
--
--   ★ 自動完了ループ（index.html:10443）は status を 完了 にするだけなので
--     このトリガーは発火しない。多端末による重複送信は起きない。
DROP TRIGGER IF EXISTS trg_eli_notify_schedule_fixed ON public.orders;
CREATE TRIGGER trg_eli_notify_schedule_fixed
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW
  WHEN (
        NEW.status IS DISTINCT FROM OLD.status
    AND NEW.status = '日程確定'
    AND NEW.deleted_at IS NULL
  )
  EXECUTE FUNCTION public.eli_notify_schedule_fixed();


-- ================================================================
-- STEP 6 : 検証
-- ================================================================

-- 6-1. トリガーが1つだけ付いているか
SELECT tgname, pg_get_triggerdef(oid) AS definition
FROM   pg_trigger
WHERE  tgrelid = 'public.orders'::regclass AND NOT tgisinternal;

-- 6-2. anon / authenticated から関数が剥がれているか（両方 false が正）
SELECT has_function_privilege('anon',
         'public.eli_notify_schedule_fixed()', 'EXECUTE') AS anon_can_execute,
       has_function_privilege('authenticated',
         'public.eli_notify_schedule_fixed()', 'EXECUTE') AS authenticated_can_execute;

-- 6-3. Vault に2件入っているか（値は出さない）
SELECT name, created_at FROM vault.secrets
WHERE  name IN ('eli_notify_secret','eli_notify_url') ORDER BY name;

-- 6-4. ★実弾テスト（自分のテスト案件で1件だけ実行する）
--   下の 'テスト用の受付番号' を、自分がログインできるアカウントに
--   紐づいたテスト案件の id に置き換える。
--   本番の顧客案件では絶対に実行しないこと（実際にメールが届く）。
--
--   UPDATE public.orders SET status = '日程相談中' WHERE id = 'テスト用の受付番号';
--   UPDATE public.orders SET status = '日程確定'   WHERE id = 'テスト用の受付番号';

-- 6-5. pg_net の実行結果（HTTP 応答）を確認する
--   200 かつ {"success":true} なら送信成功。
--   401 ならシークレット不一致（Vault と Edge Function Secrets を照合）。
--   404 なら関数名かURLの誤り。
SELECT id, status_code, content, created
FROM   net._http_response
ORDER  BY id DESC
LIMIT  10;

-- 6-6. 送信ログ
SELECT created_at, order_id, event, result, detail, to_domain
FROM   public.eli_email_log
ORDER  BY created_at DESC
LIMIT  20;


-- ================================================================
-- ROLLBACK（切り戻し）
-- ================================================================
--   トリガーだけ落とせば通知は即座に止まる。
--   Edge Function もログテーブルも残したまま無害化できる。
--
--     DROP TRIGGER IF EXISTS trg_eli_notify_schedule_fixed ON public.orders;
--
--   完全に撤去する場合:
--     DROP TRIGGER IF EXISTS trg_eli_notify_schedule_fixed ON public.orders;
--     DROP FUNCTION IF EXISTS public.eli_notify_schedule_fixed();
--     DELETE FROM vault.secrets WHERE name IN ('eli_notify_secret','eli_notify_url');
--     -- ログは監査記録なので残すことを推奨
--     -- DROP TABLE IF EXISTS public.eli_email_log;
-- ================================================================
