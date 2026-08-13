-- ================================================================
-- E-Li Web Push Phase 2 : eli_push_subscriptions に
--                          「自分の行だけ」の SELECT ポリシーを足す
--
--   症状（2026-08-13・本番）:
--     購読を許可すると upsert が 403 で落ちる。
--       new row violates row-level security policy
--       for table "eli_push_subscriptions"
--
--   ★原因（切り分け済み・確定）
--
--     upsert は PostgREST が
--       INSERT ... ON CONFLICT (endpoint) DO UPDATE SET ...
--     を発行する。ON CONFLICT DO UPDATE が付くと、競合行を扱うために
--     PostgreSQL は **SELECT ポリシーも適用する**。素の INSERT では
--     評価されない経路。
--
--     このテーブルは §14-4 の「クライアントから読ませない」を
--     SELECT ポリシーを1本も作らないことで実現していた。
--     適用可能な SELECT ポリシーが存在しない＝全拒否なので、
--     行の内容や auth.uid() の値と無関係に upsert は必ず落ちる。
--     テーブルが0行でも落ちる（競合行の有無ではなくポリシーの不在が理由）。
--
--   ★切り分けの根拠（推測ではなく実測）
--     ・auth.uid() は正常。同じ管理者アカウントで案件に写真を追加したところ
--       order_change_logs への INSERT が成功し、変更通知まで生成された。
--       そのポリシーは with check (changed_by = auth.uid())
--     ・Authorization ヘッダは載っており、ロールは authenticated
--       （anon なら INSERT 権限が無いので 42501 permission denied になる。
--         実際に返ったのは RLS violation で、権限は通っている）
--     ・payload の user_id は本人の UUID で正しい
--     ・両テーブルの構造的な違いは「素の INSERT か ON CONFLICT 付きか」と
--       「SELECT ポリシーの有無」の2点だけ。order_change_logs には
--       SELECT ポリシー（order_change_logs_admin_select）がある
--
--   ★設計時の見落とし
--     ON CONFLICT が要求するのは SELECT「権限」だけだと考えて、
--     権限は付与し（C-3 で a_select = true を確認）ポリシーは作らなかった。
--     実際にはポリシーも要る。§14-4 を更新すること。
--
--   ★このファイルは SELECT ポリシーを1本足すだけ。
--     既存の2本（insert / update）・権限・列・インデックスには触れない。
--
--   実行順序: STEP A → STEP B（検証）
--     Supabase の SQL Editor は複数文をまとめると最後の SELECT しか
--     表示しないので、STEP ごとに個別実行すること。
-- ================================================================


-- ================================================================
-- STEP A : SELECT ポリシーを追加
-- ================================================================
--   読めるのは user_id = auth.uid() の行だけ。つまり自分の端末の購読だけで、
--   その中身（endpoint と鍵）は**その端末のブラウザが既に持っている値**。
--   他人の購読は引き続き読めない。anon は権限ごと剥奪済みなので全遮断のまま。
--
--   §14-4 の「クライアントから読まない」は、
--     これまで … ポリシーが無いから読めない
--     これから … クライアントに読むコードを書かない
--   に変わる。実装は .select() を1度も呼んでおらず、
--   ensurePushSubscription() が出すのは upsert 1本だけ（負荷は不変）。
CREATE POLICY eli_push_sub_select ON public.eli_push_subscriptions
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

COMMENT ON TABLE public.eli_push_subscriptions IS
  'Web Push 購読。client=書き込み専用 / Edge Function(service_role)=読み取り専用。'
  'SELECT ポリシーは自分の行のみ（upsert の ON CONFLICT が SELECT ポリシーを'
  '要求するため必要。クライアントに読ませる意図ではない）。'
  '設計根拠は docs/notification-bell-plan.md §14-4。';


-- ================================================================
-- STEP B : 検証（SELECT のみ・副作用なし。1つずつ流す）
-- ================================================================

-- B-1 ポリシーが3本になったか
SELECT policyname, cmd, roles, qual, with_check
  FROM pg_policies
 WHERE schemaname='public' AND tablename='eli_push_subscriptions'
 ORDER BY cmd, policyname;
--   期待: 3行。
--     eli_push_sub_insert | INSERT | {authenticated} | qual=NULL              | with_check=(user_id = auth.uid())
--     eli_push_sub_select | SELECT | {authenticated} | qual=(user_id = auth.uid()) | with_check=NULL
--     eli_push_sub_update | UPDATE | {authenticated} | qual=true              | with_check=(user_id = auth.uid())
--   ★SELECT の qual が true や NULL になっていないこと（全行読めてしまう）。
--   ★DELETE / ALL のポリシーが増えていないこと。


-- B-2 anon が閉じたままか（8/13 の C-2 と同じ検査）
SELECT
  has_table_privilege('anon','public.eli_push_subscriptions','SELECT') AS anon_select,
  has_table_privilege('anon','public.eli_push_subscriptions','INSERT') AS anon_insert,
  has_table_privilege('anon','public.eli_push_subscriptions','UPDATE') AS anon_update,
  has_table_privilege('anon','public.eli_push_subscriptions','DELETE') AS anon_delete;
--   期待: 4つとも false（STEP A では権限を触っていないので変化しないはず）


-- B-3 authenticated の権限が変わっていないか
SELECT
  has_table_privilege('authenticated','public.eli_push_subscriptions','SELECT') AS a_select,
  has_table_privilege('authenticated','public.eli_push_subscriptions','INSERT') AS a_insert,
  has_table_privilege('authenticated','public.eli_push_subscriptions','UPDATE') AS a_update,
  has_table_privilege('authenticated','public.eli_push_subscriptions','DELETE') AS a_delete;
--   期待: SELECT / INSERT / UPDATE = true、DELETE = false（8/13 から不変）


-- B-4 購読が入ったかの確認（本番で「通知を許可」を押し直したあとに実行する）
--     ★endpoint の実値は秘匿値なので出さない。真偽値と件数だけ見る。
SELECT count(*)                                   AS rows,
       count(*) FILTER (WHERE user_id IS NOT NULL) AS with_user,
       max(created_at)                            AS latest
  FROM public.eli_push_subscriptions;
--   期待: rows = 1 / with_user = 1 / latest が直近の時刻
