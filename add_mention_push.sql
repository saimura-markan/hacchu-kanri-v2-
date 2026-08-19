-- ================================================================
-- メンションPush : get_push_targets_message + トリガー
--
--   【実行記録 2026-08-19】本番適用済み。検証は値で確認した（散文で済ませない）。
--     ・RPC       : public.get_push_targets_message(p_message_id bigint)
--                   SECURITY DEFINER / anon=false / authenticated=false / service_role=true
--     ・トリガー  : trg_eli_notify_mention  tgenabled=O(有効)
--                   AFTER INSERT / FOR EACH ROW / WHEN(mentions 非NULL かつ array_length>0)
--                   → 通常のチャット投稿では発火せず pg_net も走らないことを確認
--     ・宛先      : message_id=683 で宛先1名。案件の会社に属する顧客のみ。他社混入なし
--     ・フィルタ  : mentions 全23要素中1件が UUID でない旧データ（氏名文字列）。
--                   正規表現フィルタは実際に弾いている。★外すとキャストで関数ごと落ちる
--     ・⚪未検証  : 送信者本人の除外。683 は送信者が自分をメンションしておらず
--                   除外条件が発動しないため判定不能。実機で自分を含めてメンションして要確認
--
--   宛先＝そのメッセージで実際にメンションされた人のうち、
--         案件の関係者であり、送信者本人でない人。
--
--   ★実行前に必ず STEP 0 を流し、前提が合っているか値で確認すること。
--   ★STEP 0 と STEP 3 は読み取り専用。本番を変えるのは STEP 1 と STEP 2 だけ。
--   ★STEP ごとに個別に実行する（SQL Editor は最後の SELECT しか表示しない）。
--
--   負荷について（絶対原則：Supabase の負担は限りなく減らす）
--     ・トリガーは WHEN 句でメンション無しを DB 側で弾く。
--       通常のチャット投稿では関数呼び出しも pg_net も発生しない。
--     ・重複抑止（eli_notify_event の TG_ARGV[1]='case'）は使わない。
--       10分窓で同一案件の2件目以降のメンションが落ちるため。
--     ・インデックス追加なし（message_id は PK、user_id は既存インデックスあり）。
--     ・RPC は1往復で endpoint 3列＋order_id を返す。Edge Function 側の
--       追加クエリをゼロにするため order_id をここに含める。
-- ================================================================


-- ================================================================
-- STEP 0 : 前提確認（読み取り専用・1行返る）
-- ================================================================
--   ★「実行済みのつもり」を排除する。散文ではなく値で確認する。
--   ★対照を入れてあるので、判定式が死んでいれば分かる。

SELECT
  (SELECT data_type FROM information_schema.columns
    WHERE table_schema='public' AND table_name='messages' AND column_name='id')        AS "messages.id型(bigintが前提)",
  (SELECT data_type FROM information_schema.columns
    WHERE table_schema='public' AND table_name='messages' AND column_name='mentions')  AS "mentions型(ARRAYが前提)",
  (SELECT data_type FROM information_schema.columns
    WHERE table_schema='public' AND table_name='messages' AND column_name='sender_id') AS "sender_id型(uuidが前提)",
  (SELECT count(*) FROM messages
    WHERE mentions IS NOT NULL AND array_length(mentions,1) > 0)                       AS "メンション付きメッセージ数",
  -- ★旧データ救済の必要性を値で確認する（index.html にも救済分岐が残っている）
  (SELECT count(*) FROM messages m, unnest(m.mentions) AS x
    WHERE x !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
                                                                                       AS "★UUIDでない要素の数",
  -- 対照：存在しない列名なら NULL になることの確認（判定が生きているか）
  (SELECT data_type FROM information_schema.columns
    WHERE table_schema='public' AND table_name='messages' AND column_name='not_exist_zzz')
                                                                                       AS "対照_存在しない列(NULLが正)",
  CASE
    WHEN (SELECT data_type FROM information_schema.columns
           WHERE table_schema='public' AND table_name='messages' AND column_name='id') <> 'bigint'
      THEN '❌ messages.id が bigint ではない。RPC の引数型を実際の型に直してから STEP 1 に進むこと。'
    WHEN (SELECT data_type FROM information_schema.columns
           WHERE table_schema='public' AND table_name='messages' AND column_name='mentions') <> 'ARRAY'
      THEN '❌ mentions が配列ではない。設計の前提が崩れている。'
    ELSE '✅ 前提は合っている。★UUIDでない要素の数 が1以上なら、RPC の正規表現フィルタが実際に効いている（外すとキャストで関数ごと落ちる）。'
  END                                                                                  AS "判定";


-- ================================================================
-- STEP 1 : RPC 本体 ＋ 権限（★同じスクリプト内でセットにする）
-- ================================================================
--   ★宛先の判定はここに1箇所だけ置く。Edge Function 側では判定しない
--     （8/18 の get_push_targets と同じ方針。同じ規則を2箇所に持たない）。
--
--   ★mentions をそのまま信じない。
--     mentions はクライアントが書き込む text[] で、中身は検証されていない。
--     他社ユーザーの UUID を入れられればその人に Push が飛ぶ。
--     get_mention_candidates と同じ規則（社内 ∪ 当該 company_id の顧客）で絞り直す。
--
--   ★旧データに氏名文字列が混在している。
--     m.mentions::uuid[] と素直にキャストすると invalid input syntax で
--     関数ごと落ちる。UUID 形式の要素だけを通す。

CREATE OR REPLACE FUNCTION public.get_push_targets_message(p_message_id bigint)
RETURNS TABLE (
  endpoint text,
  p256dh   text,
  auth_key text,
  order_id text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
  WITH msg AS (
    SELECT m.id, m.order_id, m.sender_id, m.mentions, o.company_id
    FROM messages m
    JOIN orders   o ON o.id = m.order_id
    WHERE m.id = p_message_id
  ),
  -- UUID 形式の要素だけ通す（旧データの氏名文字列でキャスト失敗させない）
  ment AS (
    SELECT DISTINCT x::uuid AS uid
    FROM msg, unnest(msg.mentions) AS x
    WHERE x ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  ),
  -- mentions を信じず、案件の関係者に絞り直す
  allowed AS (
    SELECT ment.uid
    FROM ment
    JOIN auth.users u ON u.id = ment.uid
    WHERE ment.uid IS DISTINCT FROM (SELECT sender_id FROM msg)   -- 自分自身には送らない
      AND (
        -- 社内は無条件
        COALESCE(u.raw_app_meta_data ->> 'role', 'user') IN ('admin','manager','staff')
        -- 顧客は当該案件の会社に user_companies で紐づく人だけ
        OR EXISTS (
          SELECT 1 FROM user_companies uc
          WHERE uc.user_id    = ment.uid
            AND uc.company_id = (SELECT company_id FROM msg)
        )
      )
  )
  SELECT
    s.endpoint,
    s.p256dh,
    s.auth_key,
    (SELECT msg.order_id FROM msg)     -- 全行同じ値。sw.js が ?order= に使う
  FROM eli_push_subscriptions s
  JOIN allowed  a ON a.uid = s.user_id
  JOIN profiles p ON p.id  = s.user_id
  WHERE COALESCE(p.is_system, false) = false
    AND COALESCE(p.eli_notification_excluded, false) = false;
$$;

COMMENT ON FUNCTION public.get_push_targets_message(bigint) IS
  'メンションPush の宛先。mentions を信じず案件の関係者に絞り直し、送信者本人と '
  'is_system / eli_notification_excluded を除く。order_id を同時に返して Edge Function の往復を1回に保つ。';

-- ★順序厳守：先に明示 GRANT、そのあとで剥奪。
--   逆順だと明示 GRANT が無い状態で PUBLIC から剥がすことになり、
--   service_role まで EXECUTE を失う。
GRANT  EXECUTE ON FUNCTION public.get_push_targets_message(bigint) TO service_role;
REVOKE EXECUTE ON FUNCTION public.get_push_targets_message(bigint) FROM PUBLIC, anon, authenticated;


-- ================================================================
-- STEP 2 : トリガー関数 ＋ トリガー
-- ================================================================
--   eli_notify_event() は order_id を送る前提なので流用できない。
--   送る中身が違う（message_id）ため専用に1本作る。
--   ★設計の骨格（絶対に INSERT を失敗させない・送るのは id と event だけ）は
--     eli_notify_event() を踏襲する。

CREATE OR REPLACE FUNCTION public.eli_notify_mention()
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
    RAISE WARNING '[eli_notify_mention] vault secret missing. message %', NEW.id;
    RETURN NEW;
  END IF;

  -- ★送るのは event と message_id だけ。宛先も本文も渡さない。
  --   宛先解決は Edge Function が get_push_targets_message で行う。
  PERFORM net.http_post(
    url     := v_url,
    body    := jsonb_build_object(
                 'event',      'mention',
                 'message_id', NEW.id::text
               ),
    headers := jsonb_build_object(
                 'Content-Type',        'application/json',
                 'x-eli-notify-secret', v_secret
               ),
    timeout_milliseconds := 5000
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- ★何があってもチャット投稿そのものは成功させる。通知は付加機能。
  RAISE WARNING '[eli_notify_mention] message %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

-- ★WHEN 句でメンション無しを DB 側で弾く。
--   通常のチャット投稿では関数本体が1度も呼ばれない（ここが負荷の要）。
--   空配列 '{}' は array_length が NULL を返すため、NULL > 0 は false になり発火しない。
DROP TRIGGER IF EXISTS trg_eli_notify_mention ON public.messages;
CREATE TRIGGER trg_eli_notify_mention
  AFTER INSERT ON public.messages
  FOR EACH ROW
  WHEN (NEW.mentions IS NOT NULL AND array_length(NEW.mentions, 1) > 0)
  EXECUTE FUNCTION public.eli_notify_mention();


-- ================================================================
-- STEP 3 : 検証（読み取り専用・1行返る）
-- ================================================================
--   ★「作ったつもり」を潰す。権限・トリガー・宛先の3つを値で確認する。
--   ★対照2列を併記し、判定関数が死んでいて false を返しているだけ、
--     という状態と区別する。

SELECT
  -- 権限
  has_function_privilege('anon',          'public.get_push_targets_message(bigint)', 'EXECUTE') AS "anon(falseが正)",
  has_function_privilege('authenticated', 'public.get_push_targets_message(bigint)', 'EXECUTE') AS "authenticated(falseが正)",
  has_function_privilege('service_role',  'public.get_push_targets_message(bigint)', 'EXECUTE') AS "★service_role(trueが必須)",
  -- トリガー
  (SELECT count(*) FROM pg_trigger
    WHERE tgname = 'trg_eli_notify_mention' AND NOT tgisinternal)                     AS "トリガー数(1が正)",
  -- 対照：判定が生きているか
  has_function_privilege('anon', 'pg_catalog.now()', 'EXECUTE')                       AS "対照_anonにtrueを返せる(trueが正)",
  has_function_privilege('anon', 'pg_catalog.pg_read_file(text)', 'EXECUTE')          AS "対照_falseも返せる(falseが正)",
  CASE
    WHEN NOT has_function_privilege('anon', 'pg_catalog.now()', 'EXECUTE')
      THEN '❌ 対照が失敗。判定が死んでいるので false は塞げた証拠にならない。'
    WHEN has_function_privilege('anon', 'public.get_push_targets_message(bigint)', 'EXECUTE')
      THEN '❌ anon から実行できる。REVOKE が効いていない。'
    WHEN NOT has_function_privilege('service_role', 'public.get_push_targets_message(bigint)', 'EXECUTE')
      THEN '❌ service_role が実行できない。Edge Function が宛先解決で失敗する。'
    WHEN (SELECT count(*) FROM pg_trigger
           WHERE tgname='trg_eli_notify_mention' AND NOT tgisinternal) = 0
      THEN '❌ トリガーが作られていない。'
    ELSE '✅ 権限・トリガーとも正常。次は下のカナリアで宛先を確認すること。'
  END                                                                                 AS "判定";


-- ================================================================
-- STEP 4 : ★宛先カナリア（読み取り専用・実データで確認）
-- ================================================================
--   ★実在するメンション付きメッセージで、宛先が誰になるかを目視する。
--     <ここにmessage_id> は STEP 0 で件数を確認したうえで実物の id を入れる。
--   ★endpoint / p256dh / auth_key の実値は出さない（public リポジトリ対策）。
--   ★送信者本人が宛先に出ていないこと、他社の人が出ていないことを確認する。
--
-- WITH t AS (
--   SELECT g.endpoint, g.order_id
--   FROM public.get_push_targets_message(<ここにmessage_id>) g
-- )
-- SELECT
--   t.order_id                                        AS "案件",
--   left(md5(t.endpoint), 8)                          AS "端末キー",
--   p.name                                            AS "宛先名",
--   COALESCE(u.raw_app_meta_data ->> 'role','user')   AS "role",
--   (SELECT string_agg(DISTINCT co.name, ' / ')
--      FROM user_companies uc JOIN companies co ON co.id = uc.company_id
--     WHERE uc.user_id = s.user_id)                   AS "宛先の所属会社",
--   CASE WHEN s.user_id = (SELECT sender_id FROM messages WHERE id = <ここにmessage_id>)
--        THEN '❌NG: 送信者本人が宛先に入っている'
--        ELSE '✅OK' END                              AS "判定"
-- FROM t
-- LEFT JOIN eli_push_subscriptions s ON s.endpoint = t.endpoint
-- LEFT JOIN profiles   p ON p.id = s.user_id
-- LEFT JOIN auth.users u ON u.id = s.user_id;


-- ================================================================
-- 付録 : 撤去手順（kill switch）
-- ================================================================
--   Push が暴走した場合、トリガーだけ落とせば送信は即止まる。
--   RPC は残しても実害が無い（service_role からしか呼べない）。
--
-- DROP TRIGGER IF EXISTS trg_eli_notify_mention ON public.messages;
