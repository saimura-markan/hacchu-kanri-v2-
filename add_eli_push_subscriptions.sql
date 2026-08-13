-- ================================================================
-- E-Li Web Push Phase 2 : 購読テーブル eli_push_subscriptions
--
--   設計の根拠は docs/notification-bell-plan.md §14-4。
--   ★絶対原則: Supabase の負担を限りなく減らす。重くなるのは悪。
--
--   このテーブルの負荷特性（意図した設計）
--     ・書き込み … 1端末あたり生涯数回だけ。クライアントは localStorage に
--                  前回の endpoint を持ち、変化したときしか upsert しない。
--                  素直に実装すると全ページロードで upsert が飛ぶ。
--                  ここが単独で最大の削減点。
--     ・読み取り … クライアントからは0回。読むのは Edge Function
--                  (service_role) のみ。
--     ・定期実行 … 無し。pg_cron の掃除ジョブは作らない（定期実行そのものが
--                  恒常負荷）。死んだ購読は Edge Function が 404/410 を
--                  受けたその場で DELETE する。
--     ・トリガー … 無し。送信は既存 eli_notify_event() ＋
--                  send-order-notification に相乗りする（DB 側の追加負荷ゼロ）。
--   想定行数は端末込みでも数十行規模。endpoint のハッシュ化や凝った分割は
--   この規模では過剰で、複雑さという別の重さを持ち込むだけなので採らない。
--
--   ★このリポジトリは public。鍵・endpoint などの実値を書かないこと。
--     このファイルは DDL のみで、実値を一切含まない。
--
--   ★実行順序: STEP A → STEP B → STEP C（検証）
--     Supabase の SQL Editor は複数文をまとめて流すと
--     「最後の SELECT の結果」しか表示しない（2026-08-03 の教訓）。
--     STEP ごとにコピーして個別に実行し、都度結果を確認すること。
--
--   ★このファイルは eli_push_subscriptions 以外のオブジェクトに触れない。
--     既存テーブル・RPC・RLS・トリガーへの変更は1行も含まない。
-- ================================================================


-- ================================================================
-- STEP A : テーブル本体
-- ================================================================
--   PK を endpoint にするのが要点。
--   クライアントは「今あるか」を問い合わせずに upsert 1本で完結でき、
--   重複判定のための SELECT が発生しない。
--
--   endpoint は Push サービス（FCM / Apple）が発行する URL で、
--   端末＋ブラウザ＋購読ごとに一意。同じ人が PC と iPhone から使えば2行になる。
CREATE TABLE IF NOT EXISTS public.eli_push_subscriptions (
  endpoint    text        PRIMARY KEY,
  user_id     uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  p256dh      text        NOT NULL,
  auth_key    text        NOT NULL,
  ua          text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  last_ok_at  timestamptz,
  fail_count  smallint    NOT NULL DEFAULT 0
);

-- Edge Function が「この人の端末一覧」を引くための唯一のインデックス。
-- これ以外は作らない（インデックスは書き込みコストとして跳ね返る）。
CREATE INDEX IF NOT EXISTS idx_eli_push_subscriptions_user
  ON public.eli_push_subscriptions (user_id);


-- ---- COMMENT（設計意図をDBに残す。後から来た人がここだけ読めば分かるように）----
COMMENT ON TABLE public.eli_push_subscriptions IS
  'Web Push 購読。client=書き込み専用 / Edge Function(service_role)=読み取り専用。'
  'RLS に SELECT ポリシーを作らないため authenticated からは常に0行に見える。'
  '設計根拠は docs/notification-bell-plan.md §14-4。';

COMMENT ON COLUMN public.eli_push_subscriptions.endpoint IS
  'PushSubscription.endpoint。PK にしてあるので client は SELECT 無しの'
  'upsert 1本で済む。端末からしか取得できない秘匿値として扱う。';

COMMENT ON COLUMN public.eli_push_subscriptions.auth_key IS
  'PushSubscription.keys.auth。★列名を auth にしないこと。'
  'PostgreSQL は x.y() を「スキーマ x の関数 y」とも解釈するため、'
  'auth という列があると RLS 内の auth.uid() の解決が壊れうる。';

COMMENT ON COLUMN public.eli_push_subscriptions.ua IS
  'navigator.userAgent。どの端末の購読か調べるためだけの参考値。'
  '通知の宛先選定には使わない。';

COMMENT ON COLUMN public.eli_push_subscriptions.last_ok_at IS
  '★送信成功のたびに書かないこと。通知1件×端末数の UPDATE が恒常的に'
  '発生して絶対原則に反する。障害調査時に手動で使う枠として置いてあるだけ。';

COMMENT ON COLUMN public.eli_push_subscriptions.fail_count IS
  '一時エラーの累積。404/410（購読が死んだ）は加算せず、'
  'Edge Function がその場で DELETE する（§14-4）。';


-- ================================================================
-- STEP B : RLS と権限
-- ================================================================
--   ★新規テーブルは ALTER DEFAULT PRIVILEGES により anon / authenticated へ
--     SELECT/INSERT/UPDATE/DELETE が自動で付く。
--     RLS を有効にしただけでは足りず、明示的な REVOKE が要る。
--     （2026-08-12 に共有 Supabase の RLS 無効テーブルを緊急封鎖したのと同じ論点）
ALTER TABLE public.eli_push_subscriptions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.eli_push_subscriptions FROM PUBLIC, anon, authenticated;

--   SELECT を含める理由:
--     PostgreSQL の INSERT ... ON CONFLICT DO UPDATE は、更新式で読む列に
--     SELECT「権限」を要求する。権限を外すと upsert が 42501 で落ちうる。
--     ただし SELECT「ポリシー」を1つも作らないので、
--     authenticated が実際に読める行は常に0行になる。
--     §14-4 の「クライアントから読まない」は RLS 側で担保する。
--   DELETE を含めない理由:
--     利用者が通知を止めるときは SW 側で unsubscribe() すれば endpoint が
--     無効になり、次の送信で Edge Function が 410 を受けて自動削除する。
--     行を消すためだけに権限とポリシーを増やさない。
GRANT INSERT, UPDATE, SELECT ON public.eli_push_subscriptions TO authenticated;

--   anon には何も与えない（上の REVOKE のまま）。
--   service_role の権限は触らない（既定のまま。RLS はバイパスされる）。


-- 自分の user_id でしか行を作れない
CREATE POLICY eli_push_sub_insert ON public.eli_push_subscriptions
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

--   USING (true) にする理由:
--     同じ PC・同じブラウザを別の社員アカウントで使うと、endpoint は同じまま
--     user_id だけが変わる。USING (user_id = auth.uid()) にすると
--     その端末では以後ずっと購読できず、しかも原因が分かりにくい。
--     endpoint は当該端末からしか取得できない秘匿値なので、
--     引き継ぎを許す側に倒す。WITH CHECK で「他人名義の行は作れない」は維持する。
CREATE POLICY eli_push_sub_update ON public.eli_push_subscriptions
  FOR UPDATE TO authenticated
  USING (true)
  WITH CHECK (user_id = auth.uid());

--   ★SELECT ポリシーは作らない … クライアントから読ませない
--   ★DELETE ポリシーは作らない … 死んだ購読は Edge Function が消す
--   ★ALL のポリシーは作らない   … 上2本より広い権限を与えないため


-- ================================================================
-- STEP C : 検証（SELECT のみ。副作用なし。1つずつ流して結果を確認する）
-- ================================================================

-- C-1 RLS が有効か
SELECT relname, relrowsecurity, relforcerowsecurity
  FROM pg_class WHERE oid = 'public.eli_push_subscriptions'::regclass;
--   期待: relrowsecurity = true


-- C-2 anon に権限が残っていないか
SELECT
  has_table_privilege('anon','public.eli_push_subscriptions','SELECT') AS anon_select,
  has_table_privilege('anon','public.eli_push_subscriptions','INSERT') AS anon_insert,
  has_table_privilege('anon','public.eli_push_subscriptions','UPDATE') AS anon_update,
  has_table_privilege('anon','public.eli_push_subscriptions','DELETE') AS anon_delete;
--   期待: 4つとも false


-- C-3 authenticated の権限
SELECT
  has_table_privilege('authenticated','public.eli_push_subscriptions','SELECT') AS a_select,
  has_table_privilege('authenticated','public.eli_push_subscriptions','INSERT') AS a_insert,
  has_table_privilege('authenticated','public.eli_push_subscriptions','UPDATE') AS a_update,
  has_table_privilege('authenticated','public.eli_push_subscriptions','DELETE') AS a_delete;
--   期待: a_select / a_insert / a_update = true、a_delete = false


-- C-4 ポリシーが INSERT と UPDATE の2本だけか
SELECT policyname, cmd, roles, qual, with_check
  FROM pg_policies
 WHERE schemaname='public' AND tablename='eli_push_subscriptions'
 ORDER BY policyname;
--   期待: 2行のみ。
--     eli_push_sub_insert | INSERT | {authenticated} | qual=NULL | with_check=(user_id = auth.uid())
--     eli_push_sub_update | UPDATE | {authenticated} | qual=true  | with_check=(user_id = auth.uid())
--   SELECT / DELETE / ALL のポリシーが無いこと。


-- C-5 トリガーが1本も付いていないこと
SELECT count(*) AS trigger_count
  FROM pg_trigger
 WHERE tgrelid = 'public.eli_push_subscriptions'::regclass AND NOT tgisinternal;
--   期待: 0


-- C-6 インデックスが PK と user_id の2本だけか
SELECT indexname, indexdef
  FROM pg_indexes
 WHERE schemaname='public' AND tablename='eli_push_subscriptions'
 ORDER BY indexname;
--   期待: 2行（eli_push_subscriptions_pkey / idx_eli_push_subscriptions_user）


-- C-7 列構成の最終確認
SELECT column_name, data_type, is_nullable, column_default
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='eli_push_subscriptions'
 ORDER BY ordinal_position;
--   期待: endpoint / user_id / p256dh / auth_key / ua /
--         created_at / last_ok_at / fail_count の8列。
--         ★auth という名前の列が無いこと。
