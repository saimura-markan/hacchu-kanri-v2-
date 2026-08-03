-- ================================================================
-- E-Li 顧客メール通知 第2段階 — 4イベント化
--   受付（INSERT）/ キャンセル / 日程相談中 を追加し、
--   日程確定を含む4イベントを1つの汎用トリガー関数で扱う。
--
--   前提: Edge Function send-order-notification の新版
--         （4イベント対応・宛名差し込み・平文併記）を
--         ★先にデプロイして動作確認を済ませておくこと。
--
--         新版は既存トリガーと後方互換（event='schedule_fixed' を
--         同じペイロードで受ける）なので、EF を先に入れても
--         日程確定メールが止まる瞬間は生じない。
--         逆順にすると、EF が知らないイベントを投げる空白ができる。
--
--   ★ 実行順序（1ブロックずつ流し、都度結果を確認する）
--     STEP A → STEP B → STEP C → STEP D（検証）→ テスト送信
--     STEP E は任意。今日やらなくても機能は完成する。
--
--   ★ Supabase の SQL Editor は複数文をまとめて流すと
--     「最後の SELECT の結果」しか表示しない。
--     STEP ごとにコピーして個別に実行すること。
--
--   ★ このリポジトリは public。シークレットの実値を書かないこと。
--     このファイルは Vault 参照のみで、実値を含まない。
--
--   STEP 0 の実測（2026-08-03 / check_orders_status_default.sql）:
--     0-1 orders.status の既定値 … '調整中'
--     0-2 ステータス分布        … 完了 / 日程確定 / キャンセル（想定内）
--     0-3 orders のトリガー     … trg_eli_notify_schedule_fixed
--                                  trg_set_order_user_id の2本のみ
--                                  （他システムのものは無い）
--     0-4 1 case あたりの orders … 複数行の case が27件・最大11行
--                                  case_id が NULL の行は0件
--     0-5 profiles.name         … E-Li 利用者15名全員が実名
-- ================================================================


-- ================================================================
-- STEP A : 送信済み抑止テーブル
-- ================================================================
--   なぜ必要か:
--     index.html は複数日程の発注を「1日程 = orders 1行」で
--     ループ INSERT する（:3366 / :4583）。配列の一括 INSERT ではなく
--     1行ごとに別トランザクションになるため、素直に AFTER INSERT
--     トリガーを張ると日程の数だけ受付メールが飛ぶ（実測最大11通）。
--
--   方式: case_id 単位・10分の時間窓。
--     ・発注直後の連続 INSERT      → 1通に抑制
--     ・追加日程依頼の連続 INSERT  → 1通に抑制
--     ・後日の追加日程依頼         → 通す
--
--     恒久抑止（DO NOTHING）にすると、既存案件への追加日程依頼
--     （:4534 handleAddRequest / :4583 handleAddFormSubmit）が
--     永久に無音になる。これらは case_id を元案件と共有するため。
--     しかも追加経路は LiBot が「追加日程依頼を受け付けました！」と
--     チャット投稿している（:4553 / :4603）ので、
--     アプリ内では応答しつつメールだけ沈黙する形になってしまう。
CREATE TABLE IF NOT EXISTS public.eli_email_sent (
  dedup_key  text        NOT NULL,
  event      text        NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dedup_key, event)
);

COMMENT ON TABLE public.eli_email_sent IS
  'E-Li 顧客メール通知の重複抑止。イベントごとに dedup_key 単位で '
  '直近の送信時刻を保持する。eli_notify_event() だけが書き込む。';

COMMENT ON COLUMN public.eli_email_sent.dedup_key IS
  'COALESCE(orders.case_id, orders.id)。案件単位で束ねるためのキー。';

ALTER TABLE public.eli_email_sent ENABLE ROW LEVEL SECURITY;

--   ポリシーを1つも作らない = service_role とテーブル所有者以外は読めない。
--   トリガー関数は SECURITY DEFINER なので RLS の影響を受けない。
--   このテーブルは運用者が直接見る必要が無いため authenticated にも開けない。
REVOKE ALL ON public.eli_email_sent FROM PUBLIC, anon, authenticated;


-- ================================================================
-- STEP B : 汎用トリガー関数
-- ================================================================
--   既存の eli_notify_schedule_fixed() はイベントキーが
--   'schedule_fixed' にハードコードされている。
--   イベントごとに関数をコピーすると以後の修正が4箇所になるため、
--   TG_ARGV で受け取る1本に集約する。
--
--   引数:
--     TG_ARGV[0] … イベントキー（Edge Function の EVENTS のキーと一致させる）
--     TG_ARGV[1] … 'case' を渡すと重複抑止を有効にする。省略時は無効。
--
--   ★ 設計上の要点（第1段階から引き継ぎ）
--
--   (1) この関数は絶対に INSERT / UPDATE を失敗させない。
--       Vault が読めない・pg_net が無い・抑止テーブルが無い —— どの異常でも
--       WARNING を出して NEW を返すだけにする。メール通知は付加機能であり、
--       発注や日程確定という業務操作を巻き込んで失敗させてはならない（§12-2）。
--
--   (2) net.http_post は非同期。リクエストをキューに積んで即座に戻り、
--       実際の送信は background worker がトランザクション後に行う。
--       したがって発注の応答時間には実質的に影響しない（同 §12-1）。
--
--   (3) 送るのは order_id と event だけ。宛先も案件情報も渡さない。
--       宛先解決は Edge Function 側で orders → auth.users と辿る。
--
--   (4) SECURITY DEFINER。vault.decrypted_secrets は postgres 以外読めないため。
CREATE OR REPLACE FUNCTION public.eli_notify_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, vault, pg_temp
AS $$
DECLARE
  -- 抑止の時間窓。ここだけ変えれば挙動を調整できる。
  v_window  constant interval := interval '10 minutes';

  v_event   text := COALESCE(TG_ARGV[0], 'schedule_fixed');
  v_dedup   text := CASE WHEN TG_NARGS >= 2 THEN TG_ARGV[1] ELSE NULL END;
  v_key     text;
  v_rows    integer;
  v_url     text;
  v_secret  text;
BEGIN
  -- ── 重複抑止（TG_ARGV[1]='case' のときだけ） ──────────────
  --   ON CONFLICT DO UPDATE は競合行にロックを取るため、
  --   同時 INSERT でも直列化される。ログテーブルを SELECT して
  --   判定する方式は、pg_net が非同期かつ複数リクエストがほぼ同時に
  --   走るため取りこぼす。
  --
  --   ROW_COUNT の意味:
  --     1 … 新規挿入 または 窓を過ぎていたので更新 → 送る
  --     0 … 窓の内側に送信済みの記録がある        → 送らない
  IF v_dedup = 'case' THEN
    v_key := COALESCE(NEW.case_id::text, NEW.id::text);

    INSERT INTO public.eli_email_sent AS s (dedup_key, event, created_at)
    VALUES (v_key, v_event, now())
    ON CONFLICT (dedup_key, event) DO UPDATE
       SET created_at = now()
     WHERE s.created_at < now() - v_window;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows = 0 THEN
      RETURN NEW;   -- 同一案件で送信済み。2通目以降は送らない
    END IF;
  END IF;

  -- ── 接続情報の取得 ────────────────────────────────────
  SELECT decrypted_secret INTO v_url
  FROM   vault.decrypted_secrets WHERE name = 'eli_notify_url';

  SELECT decrypted_secret INTO v_secret
  FROM   vault.decrypted_secrets WHERE name = 'eli_notify_secret';

  IF v_url IS NULL OR v_secret IS NULL THEN
    RAISE WARNING '[eli_notify] vault secret missing; skipped order % event %',
      NEW.id, v_event;
    RETURN NEW;
  END IF;

  -- ── Edge Function を非同期に叩く ─────────────────────────
  PERFORM net.http_post(
    url     := v_url,
    body    := jsonb_build_object(
                 'event',    v_event,
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
  -- ★ 何があっても本体の INSERT / UPDATE は成功させる。
  RAISE WARNING '[eli_notify] order % event %: %', NEW.id, v_event, SQLERRM;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.eli_notify_event() IS
  'E-Li 顧客メール通知。TG_ARGV[0] のイベントキーで Edge Function '
  'send-order-notification を非同期に叩く。TG_ARGV[1]=''case'' で '
  'case_id 単位・10分窓の重複抑止を有効化する。'
  '失敗しても本体の INSERT / UPDATE は成功させる。E-Li 専用。';

--   ★ anon の剥奪は「FROM PUBLIC, anon」と明示する。
--     Supabase の ALTER DEFAULT PRIVILEGES が public スキーマの関数に
--     anon への EXECUTE を明示付与するため、FROM PUBLIC だけでは剥がれない
--     （2026-07-29 fix_rpc_anon_grants.sql で確認済みの挙動）。
REVOKE ALL ON FUNCTION public.eli_notify_event()
  FROM PUBLIC, anon, authenticated;


-- ================================================================
-- STEP C : トリガー3本を追加
-- ================================================================
--   既存の trg_eli_notify_schedule_fixed には触らない。
--   ここまでは純粋な追加であり、日程確定メールは動き続ける。

-- ── C-1. 発注受付（AFTER INSERT） ───────────────────────────
--   ★ 重複抑止を有効にする唯一のトリガー（第2引数 'case'）。
--
--   ★ WHEN 句に user_id の条件を入れていない。
--     user_id が無い案件は Edge Function 側が skip し、
--     eli_email_log に 'order has no user_id' として残る。
--     WHEN 句で落とすと何も記録されず、原因追跡ができなくなる。
--
--   ★ 初期 status は '調整中'（DB 既定値・STEP 0 で確認済み）。
--     Edge Function 側の expectedStatus と一致している必要がある。
DROP TRIGGER IF EXISTS trg_eli_notify_order_received ON public.orders;
CREATE TRIGGER trg_eli_notify_order_received
  AFTER INSERT ON public.orders
  FOR EACH ROW
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE FUNCTION public.eli_notify_event('order_received', 'case');

-- ── C-2. キャンセル確定 ────────────────────────────────────
--   顧客の「キャンセル相談中」は対象外。当社が確定させた時だけ送る。
DROP TRIGGER IF EXISTS trg_eli_notify_cancelled ON public.orders;
CREATE TRIGGER trg_eli_notify_cancelled
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW
  WHEN (
        NEW.status IS DISTINCT FROM OLD.status
    AND NEW.status = 'キャンセル'
    AND NEW.deleted_at IS NULL
  )
  EXECUTE FUNCTION public.eli_notify_event('cancelled');

-- ── C-3. 日程相談中（当社都合で別日を相談） ──────────────────
--   顧客発の「日程変更相談中」とは別ステータス。混同しないこと。
--   日程相談中へ遷移させているのは AdminApp の2箇所だけ
--   （index.html:7578 の相談ボタン / :7954 のステータスセレクト）。
--
--   ★ 日程確定 ⇄ 日程相談中 を往復すると都度メールが飛ぶ。仕様。
DROP TRIGGER IF EXISTS trg_eli_notify_schedule_consult ON public.orders;
CREATE TRIGGER trg_eli_notify_schedule_consult
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW
  WHEN (
        NEW.status IS DISTINCT FROM OLD.status
    AND NEW.status = '日程相談中'
    AND NEW.deleted_at IS NULL
  )
  EXECUTE FUNCTION public.eli_notify_event('schedule_consult');


-- ================================================================
-- STEP D : 検証（1つずつ実行する）
-- ================================================================

-- D-1. トリガーが5本になっているか
--   期待:
--     trg_eli_notify_cancelled
--     trg_eli_notify_order_received
--     trg_eli_notify_schedule_consult
--     trg_eli_notify_schedule_fixed   ← 既存（まだ旧関数を指している）
--     trg_set_order_user_id           ← 既存・無関係
SELECT tgname, pg_get_triggerdef(oid) AS definition
FROM   pg_trigger
WHERE  tgrelid = 'public.orders'::regclass AND NOT tgisinternal
ORDER  BY tgname;

-- D-2. 関数から anon / authenticated が剥がれているか（両方 false が正）
SELECT has_function_privilege('anon',
         'public.eli_notify_event()', 'EXECUTE') AS anon_can_execute,
       has_function_privilege('authenticated',
         'public.eli_notify_event()', 'EXECUTE') AS authenticated_can_execute;

-- D-3. 抑止テーブルが空で存在するか
SELECT count(*) AS rows_now FROM public.eli_email_sent;


-- ================================================================
-- STEP D-4 : 実弾テスト
-- ================================================================
--   ★ 本番の顧客案件では絶対に実行しない（実際にメールが届く）。
--     自分がログインできるテストアカウントの案件で行う。
--
--   (1) 発注受付 …… ★複数日程で発注し、メールが1通だけ届くことを確認する。
--       これが今回の山場。画面から実際に「複数日程の発注」を行う。
--       SQL で INSERT すると本番同様の経路にならないため、必ず画面から。
--
--   (2) キャンセル
--       UPDATE public.orders SET status = 'キャンセル'   WHERE id = 'テスト受付番号';
--
--   (3) 日程相談中
--       UPDATE public.orders SET status = '日程相談中'   WHERE id = 'テスト受付番号';
--
--   確認クエリ:

-- D-4a. 抑止テーブルの中身（受付テストの後）
--   複数日程で発注したのに1行しか無ければ抑止が効いている。
SELECT dedup_key, event, created_at
FROM   public.eli_email_sent
ORDER  BY created_at DESC
LIMIT  20;

-- D-4b. 送信ログ
--   受付テストで result='sent' が1行だけであること。
SELECT created_at, order_id, event, result, detail, to_domain
FROM   public.eli_email_log
ORDER  BY created_at DESC
LIMIT  20;

-- D-4c. pg_net の HTTP 応答
--   200 かつ {"success":true} なら送信成功。
--   401 …… シークレット不一致（Vault と Edge Function Secrets を照合）
--   404 …… 関数名か URL の誤り
--   200 {"skipped":...} …… ガードで停止（content に理由）
--   500 …… Resend 側
SELECT id, status_code, content, created
FROM   net._http_response
ORDER  BY id DESC
LIMIT  10;


-- ================================================================
-- STEP E : 日程確定トリガーを汎用関数へ張り替える（★任意・最後）
-- ================================================================
--   やらなくても機能は完成する。違いは
--   「同じ処理の関数が2本あるか1本か」だけ。
--
--   ★ STEP C のテストが全部通ってから実行すること。
--   ★ DDL をトランザクションで囲むため、他セッションから見て
--     トリガーが存在しない瞬間は発生しない。
--
--   BEGIN 〜 COMMIT をまとめて1回で実行する（途中で止めない）。

BEGIN;

DROP TRIGGER IF EXISTS trg_eli_notify_schedule_fixed ON public.orders;

CREATE TRIGGER trg_eli_notify_schedule_fixed
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW
  WHEN (
        NEW.status IS DISTINCT FROM OLD.status
    AND NEW.status = '日程確定'
    AND NEW.deleted_at IS NULL
  )
  EXECUTE FUNCTION public.eli_notify_event('schedule_fixed');

COMMIT;

--   張り替え後に日程確定を1回テストし、メールが届くのを確認してから
--   旧関数を落とす。順序を逆にしないこと。
--
--     DROP FUNCTION IF EXISTS public.eli_notify_schedule_fixed();


-- ================================================================
-- ROLLBACK（切り戻し）
-- ================================================================
--   トリガーを落とせば通知は即座に止まる。
--   Edge Function もテーブルも残したまま無害化できる。
--
--   個別に止める:
--     DROP TRIGGER IF EXISTS trg_eli_notify_order_received   ON public.orders;
--     DROP TRIGGER IF EXISTS trg_eli_notify_cancelled        ON public.orders;
--     DROP TRIGGER IF EXISTS trg_eli_notify_schedule_consult ON public.orders;
--
--   STEP E を実行した後に日程確定だけ元へ戻す:
--     BEGIN;
--     DROP TRIGGER IF EXISTS trg_eli_notify_schedule_fixed ON public.orders;
--     CREATE TRIGGER trg_eli_notify_schedule_fixed
--       AFTER UPDATE OF status ON public.orders
--       FOR EACH ROW
--       WHEN (NEW.status IS DISTINCT FROM OLD.status
--         AND NEW.status = '日程確定' AND NEW.deleted_at IS NULL)
--       EXECUTE FUNCTION public.eli_notify_schedule_fixed();
--     COMMIT;
--     ※ 旧関数を DROP した後は戻せない。DROP は最後の最後にすること。
--
--   完全に撤去する場合:
--     上記3つの DROP TRIGGER に加えて
--     DROP FUNCTION IF EXISTS public.eli_notify_event();
--     DROP TABLE    IF EXISTS public.eli_email_sent;
--     -- eli_email_log は監査記録なので残すことを推奨
-- ================================================================
