-- ================================================================
-- Phase 1 migration : order_change_logs に per-user 既読カラムを追加
--
--   計画書: docs/notification-bell-plan.md §2-2 〜 §2-6
--
--   目的:
--     通知ベルの「個別既読」を成立させるため、order_change_logs に
--     read_by（個人の既読）を追加する。
--     既存の confirmed_by（業務上の確認）とは意味を分離し、既存 UI
--     （index.html:8481-8500 の「✅確認済/🔔未確認」表示と
--     「確認済みにする」ボタン）は一切変更しない。
--
--       read_by      = 個人が通知を見た        → ベルの未読判定に使う
--       confirmed_by = 組織として内容を確認した → 既存の表示のまま
--
--   事前調査の結果（check_role_storage.sql 実行済み）:
--     - ロールは auth.users.raw_app_meta_data ->> 'role' が正
--     - admin/manager は 8名
--     - order_change_logs は 13件、すべて confirmed_by 設定済み（未確認0件）
--     - messages.read_by にメール文字列の残骸なし（クリーン）
--
--   通知除外（後から決定した方針）:
--     info@markan.co.jp は通知システム全体の対象外とする。
--     profiles.eli_notification_excluded = true で判定するため、
--     backfill 対象は 8名 → 7名 になる。
--
--   ★ 前提ファイル（先に実行すること）:
--     add_profiles_eli_notification_excluded.sql
--     未実行の場合は STEP 0 で例外を投げて中断する。
--
--   ★ このファイルはまだ実行しないこと。
--     レビュー後、STEP ごとに区切って実行する想定。
--
--   使い方:
--     cat add_order_change_logs_read_by.sql | pbcopy
--     → Supabase ダッシュボード > SQL Editor
-- ================================================================


-- ================================================================
-- STEP 0 : 事前アサーション（想定と違えば例外を投げて中断する）
-- ================================================================
--   backfill は取り消せないため、対象者が想定どおり8名であることを
--   実行時に機械的に検証する。1名でも増減していたら中断される。
--   （退職者のロール剥奪・新任者の追加などがあると件数が変わる）
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_admins   int;
  v_excluded int;
  v_target   int;
  v_logs     int;
  v_unconf   int;
  v_noprof   int;
BEGIN
  -- 前提: eli_notification_excluded カラムが存在すること
  --       （add_profiles_eli_notification_excluded.sql を先に実行する）
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='profiles'
      AND column_name='eli_notification_excluded'
  ) THEN
    RAISE EXCEPTION
      'profiles.eli_notification_excluded が存在しません。'
      '先に add_profiles_eli_notification_excluded.sql を実行してください。';
  END IF;

  SELECT count(*) INTO v_admins
  FROM   auth.users
  WHERE  raw_app_meta_data ->> 'role' IN ('admin', 'manager');

  SELECT count(*) INTO v_excluded
  FROM   auth.users u
  JOIN   public.profiles p ON p.id = u.id
  WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager')
    AND  p.eli_notification_excluded = true;

  SELECT count(*) INTO v_target
  FROM   auth.users u
  LEFT   JOIN public.profiles p ON p.id = u.id
  WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager')
    AND  COALESCE(p.eli_notification_excluded, false) = false;

  SELECT count(*) INTO v_noprof
  FROM   auth.users u
  LEFT   JOIN public.profiles p ON p.id = u.id
  WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager')
    AND  p.id IS NULL;

  SELECT count(*) INTO v_logs   FROM public.order_change_logs;
  SELECT count(*) INTO v_unconf FROM public.order_change_logs WHERE confirmed_by IS NULL;

  -- ★ マジックナンバー1つではなくモデル全体を検証する
  --   （総数・除外数・対象数の3つが噛み合っていることを確認）
  IF v_admins <> 8 THEN
    RAISE EXCEPTION
      'admin/manager 総数が想定と異なります（期待=8名 / 実際=%名）。'
      '対象者を確認してから再実行してください。', v_admins;
  END IF;

  IF v_excluded <> 1 THEN
    RAISE EXCEPTION
      '通知除外の admin/manager が想定と異なります（期待=1名 / 実際=%名）。'
      'add_profiles_eli_notification_excluded.sql が正しく実行されたか'
      '確認してください。', v_excluded;
  END IF;

  IF v_target <> 7 THEN
    RAISE EXCEPTION
      'backfill 対象が想定と異なります（期待=7名 / 実際=%名）。', v_target;
  END IF;

  IF v_noprof > 0 THEN
    RAISE EXCEPTION
      'profiles 行が無い admin/manager が %名 居ます。'
      '除外判定ができないため中断します。'
      'profiles 行を作成してから再実行してください。', v_noprof;
  END IF;

  RAISE NOTICE '─────────────────────────────────────';
  RAISE NOTICE '事前チェック OK';
  RAISE NOTICE '  admin/manager 総数     : %名', v_admins;
  RAISE NOTICE '  うち通知除外           : %名（info@markan.co.jp）', v_excluded;
  RAISE NOTICE '  ★backfill 対象         : %名', v_target;
  RAISE NOTICE '  order_change_logs      : %件（調査時 13件）', v_logs;
  RAISE NOTICE '  うち confirmed_by NULL : %件（調査時 0件）', v_unconf;
  RAISE NOTICE '─────────────────────────────────────';

  IF v_logs <> 13 THEN
    RAISE NOTICE '※ 行数が調査時と異なります。調査後に新しい変更が'
                 '記録された可能性があります（STEP 2 の設計により'
                 '未確認の新規行は未読のまま残るため、続行して問題ありません）。';
  END IF;
END $$;


-- ================================================================
-- STEP 1 : カラム追加
-- ================================================================
--   型は text[]。messages.read_by（alter_messages_for_chat.sql:11）が
--   text[] に UUID 文字列を格納しているため、それに揃える。
--   uuid[] にすると「read_by に自分が居るか」の判定コードが
--   messages 用と order_change_logs 用の2系統に分かれてしまう。
--
--   NOT NULL DEFAULT '{}' にすることで、アプリ側の null チェックを不要にする。
-- ----------------------------------------------------------------
ALTER TABLE public.order_change_logs
  ADD COLUMN IF NOT EXISTS read_by text[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN public.order_change_logs.read_by IS
  '個人の既読（auth.uid() の UUID 文字列を追記）。通知ベルの未読判定に使用。'
  '業務上の確認を表す confirmed_by とは意味が異なるので混同しないこと。';


-- ================================================================
-- ★★★ ここで一度止まる ★★★
-- STEP 1.5 : ALTER 直後の確認 SELECT
-- ================================================================
--   STEP 0 と STEP 1 だけを実行し、この SELECT の結果を確認してから
--   STEP 2（backfill）に進むこと。
--   この時点では read_by は全行 '{}'（空）で、既読は一切付いていない。
-- ----------------------------------------------------------------
SELECT * FROM (

  -- ① カラムが意図どおり追加されたか
  SELECT 1 AS sec, '① カラム定義' AS section,
         column_name::text AS item,
         (data_type::text
          || ' / nullable=' || is_nullable::text
          || COALESCE(' / default=' || column_default::text, ''))::text AS value
  FROM   information_schema.columns
  WHERE  table_schema = 'public' AND table_name = 'order_change_logs'
    AND  column_name = 'read_by'

  UNION ALL

  -- ② この時点では全行が空であること（backfill 未実行の確認）
  SELECT 2, '② backfill 前の状態', '総行数',
         (SELECT count(*)::text FROM public.order_change_logs)
  UNION ALL
  SELECT 2, '② backfill 前の状態', 'read_by が空の行（全行であるべき）',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE array_length(read_by, 1) IS NULL)
  UNION ALL
  SELECT 2, '② backfill 前の状態', 'read_by に何か入っている行（0 であるべき）',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE array_length(read_by, 1) IS NOT NULL)

  UNION ALL

  -- ③ backfill の対象になる行数（＝次に実行する UPDATE が触る行数）
  SELECT 3, '③ backfill 対象の事前確認', 'confirmed_by IS NOT NULL（対象）',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE confirmed_by IS NOT NULL)
  UNION ALL
  SELECT 3, '③ backfill 対象の事前確認', 'confirmed_by IS NULL（対象外・未読のまま残る）',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE confirmed_by IS NULL)

  UNION ALL

  -- ④ read_by に投入される admin/manager（通知除外を反映した最終リスト）
  --    除外されたアカウントも【除外】表示で出すので、
  --    「誰が入って誰が入らないか」を1つの表で確認できる
  SELECT 4, '④ 投入される admin/manager', u.email::text,
         format('%s%s / role=%s',
                CASE WHEN COALESCE(p.eli_notification_excluded, false)
                     THEN '【除外】' ELSE '【投入】' END,
                COALESCE(p.name, '(profiles未登録)'),
                COALESCE(u.raw_app_meta_data ->> 'role', '(なし)'))::text
  FROM   auth.users u
  LEFT   JOIN public.profiles p ON p.id = u.id
  WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager')

  UNION ALL

  -- ⑤ 投入人数の確定値
  SELECT 5, '⑤ 投入人数', '★read_by に入る人数',
         (SELECT count(*)::text FROM auth.users u
          LEFT JOIN public.profiles p ON p.id = u.id
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND COALESCE(p.eli_notification_excluded, false) = false)

) AS r
ORDER BY sec, item;

-- ----------------------------------------------------------------
-- 【STEP 1.5 の判定】
--   ① read_by / ARRAY / nullable=NO / default='{}'::text[]
--   ② 総行数 13 / read_by が空の行 13 / 何か入っている行 0
--   ③ 対象 13 / 対象外 0
--   ④ 8名が並び、顔ぶれが想定どおり
--
--   → すべて一致したら STEP 2 のコメントを外して実行する。
--   → 1つでも違ったら止めて原因を確認する。
--      この時点ではカラムを1本足しただけなので、
--      ALTER TABLE public.order_change_logs DROP COLUMN read_by;
--      で完全に元に戻せる（データは一切変更していない）。
-- ----------------------------------------------------------------


-- ================================================================
-- STEP 2 : backfill
--
--   ★★★ デフォルトでコメントアウトしてある ★★★
--   STEP 1.5 の結果を確認したうえで、下記ブロックのコメントを外して
--   これだけを単独で実行すること。
--   この UPDATE は取り消せない（read_by を戻す手段は用意していない）。
-- ================================================================
--   方針: 案A（全既読化）
--     移行時点で既に「確認済み」になっている過去ログを、
--     通知対象の admin/manager（＝除外者を除く7名）の既読扱いにする。
--     これをやらないと、read_by 追加の瞬間に過去ログが
--     一斉に未読としてベルに積まれる。
--
--   ★ 対象を「confirmed_by IS NOT NULL の行」に限定している理由:
--     計画書 §2-4 では `changed_at < now()` という条件で書いていたが、
--     それだと「調査してから実行するまでの間に顧客が現場情報を変更した」
--     場合、その新しい変更まで既読化されて見逃す。
--     confirmed_by の有無で絞れば、新しく増えた未確認の行は自動的に
--     対象外になり、未読のまま正しく残る。
--     調査時点では 13件すべてが確認済み・未確認0件なので、
--     今日実行する限り結果は「全13件を既読化」で変わらない。
--
--   各行の read_by に入るもの（重複は排除）:
--     - 既存の read_by（STEP 1 直後は空）
--     - changed_by  … その変更を書いた本人（自分の変更は自分にとって既読）
--     - confirmed_by … 確認した本人
--     - 通知対象の admin/manager 7名 … 案A の本体
--       （info@markan.co.jp は eli_notification_excluded=true のため入らない）
-- ----------------------------------------------------------------
-- ↓↓↓ 2026-07-29 コメント解除済み。このブロックだけを選択して実行する ↓↓↓
UPDATE public.order_change_logs l
SET    read_by = COALESCE((
         SELECT array_agg(DISTINCT e)
         FROM   unnest(
                  COALESCE(l.read_by, '{}')
                  || ARRAY[l.changed_by::text]
                  || ARRAY[l.confirmed_by::text]
                  || (SELECT COALESCE(array_agg(u.id::text), '{}')
                      FROM   auth.users u
                      LEFT   JOIN public.profiles p2 ON p2.id = u.id
                      WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager')
                        AND  COALESCE(p2.eli_notification_excluded, false) = false)
                ) AS e
         WHERE  e IS NOT NULL         -- changed_by / confirmed_by が NULL の場合を除外
       ), '{}')
WHERE  l.confirmed_by IS NOT NULL;    -- 未確認の行は未読のまま残す
-- ↑↑↑ ここまで ↑↑↑
--
--   ★ LEFT JOIN + COALESCE(..., false) にしている理由:
--     INNER JOIN にすると profiles 行が無い管理者が対象から丸ごと落ちる。
--     STEP 0 で profiles 未登録の管理者が居れば中断する設計にしているが、
--     二重の安全策として JOIN 側でも取りこぼさないようにしている。


-- ----------------------------------------------------------------
-- 【参考】無条件に全行を既読化したい場合はこちら（通常は使わない）
--   confirmed_by が NULL の行まで既読にしてしまうため、
--   調査後に増えた変更を見逃すリスクがある。
-- ----------------------------------------------------------------
-- UPDATE public.order_change_logs l
-- SET    read_by = COALESCE((
--          SELECT array_agg(DISTINCT e)
--          FROM   unnest(
--                   COALESCE(l.read_by, '{}')
--                   || ARRAY[l.changed_by::text]
--                   || ARRAY[l.confirmed_by::text]
--                   || (SELECT COALESCE(array_agg(u.id::text), '{}')
--                       FROM   auth.users u
--                       WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager'))
--                 ) AS e
--          WHERE  e IS NOT NULL
--        ), '{}');


-- ================================================================
-- STEP 3 : インデックス —— 判断結果：今回は作らない
-- ================================================================
--   計画書 §2-4 では GIN(read_by) と btree(changed_at) を張る前提で
--   書いていたが、実データを見た結果、方針を変更する。
--
--   【判断の根拠】
--     - order_change_logs は現在 13行。
--       この規模では PostgreSQL のプランナは確実に Seq Scan を選び、
--       インデックスは一度も使われない。
--     - 使われないインデックスは、INSERT ごとの更新コストと
--       VACUUM 対象が増えるだけの純粋な負債になる。
--     - 「インデックスを張ったから速い」という誤った安心感を残すと、
--       将来ここがボトルネックになったときの調査を遅らせる。
--     - 後から CREATE INDEX CONCURRENTLY で無停止追加できるため、
--       今作らないことによる将来コストはほぼゼロ。
--
--   【いつ作るか】
--     order_change_logs が 1,000行を超えたら下記を実行する。
--     Phase 2 で通知フィードが read_by ベースの検索と
--     ORDER BY changed_at DESC LIMIT 100 を3秒ごとに回すため、
--     そのタイミングで行数を再確認すること。
--
--   ※ CREATE INDEX CONCURRENTLY はトランザクション内で実行できない。
--     Supabase SQL Editor で他のステートメントと同時に流すと失敗するので、
--     これだけを単独で実行すること。
-- ----------------------------------------------------------------
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS order_change_logs_read_by_idx
--   ON public.order_change_logs USING gin (read_by);
--
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS order_change_logs_changed_at_idx
--   ON public.order_change_logs (changed_at DESC);


-- ================================================================
-- STEP 4 : 確認用 SELECT（実行後にこれだけを流す）
-- ================================================================
SELECT * FROM (

  -- ① カラムが意図どおり追加されたか
  SELECT 1 AS sec, '① カラム定義' AS section,
         column_name::text AS item,
         (data_type::text
          || ' / nullable=' || is_nullable::text
          || COALESCE(' / default=' || column_default::text, ''))::text AS value
  FROM   information_schema.columns
  WHERE  table_schema = 'public' AND table_name = 'order_change_logs'
    AND  column_name = 'read_by'

  UNION ALL

  -- ② backfill の結果サマリ
  --    「read_by が8名以上の行」が13件になっていれば成功
  SELECT 2, '② backfill 結果', '総行数',
         (SELECT count(*)::text FROM public.order_change_logs)
  UNION ALL
  SELECT 2, '② backfill 結果', 'read_by が空の行（未確認＝未読のまま）',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE array_length(read_by, 1) IS NULL)
  UNION ALL
  SELECT 2, '② backfill 結果', 'read_by に8名以上入った行（既読化済み）',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE array_length(read_by, 1) >= 8)
  UNION ALL
  SELECT 2, '② backfill 結果', 'read_by 要素数の最小〜最大',
         (SELECT COALESCE(min(array_length(read_by,1))::text, '-')
                 || ' 〜 ' ||
                 COALESCE(max(array_length(read_by,1))::text, '-')
          FROM public.order_change_logs)

  UNION ALL

  -- ③ confirmed_by が壊れていないこと（既存 UI の表示根拠）
  --    backfill は read_by しか触らないので、ここは調査時と同じはず
  SELECT 3, '③ confirmed_by 不変チェック', 'confirmed_by 設定済み',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE confirmed_by IS NOT NULL)
  UNION ALL
  SELECT 3, '③ confirmed_by 不変チェック', 'confirmed_by IS NULL',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE confirmed_by IS NULL)

  UNION ALL

  -- ④ 混入チェック：read_by に UUID 以外が入っていないか
  --    messages.read_by で過去に起きたメール文字列混在の再発防止
  SELECT 4, '④ read_by 中身の健全性', '@ を含む要素がある行（メール混入）',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE EXISTS (SELECT 1 FROM unnest(read_by) e WHERE e LIKE '%@%'))
  UNION ALL
  SELECT 4, '④ read_by 中身の健全性', 'UUID 形式でない要素がある行',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE EXISTS (
            SELECT 1 FROM unnest(read_by) e
            WHERE e !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'))

  UNION ALL

  -- ⑤ 実際の中身サンプル（目視確認用）
  SELECT 5, '⑤ サンプル', (l.id::text || ' / ' || l.field_name)::text,
         ('read_by=' || array_length(l.read_by,1)::text || '名'
          || ' / confirmed=' || CASE WHEN l.confirmed_by IS NULL THEN 'なし' ELSE 'あり' END
          || ' / ' || l.changed_at::text)::text
  FROM   public.order_change_logs l

  UNION ALL

  -- ⑥ messages.read_by のインデックス状況（未確認事項）
  --    3秒ポーリングで containment 検索を回しているため、
  --    GIN が無い場合は messages の行数を見て別途判断する
  SELECT 6, '⑥ messages インデックス', 'messages 行数',
         (SELECT count(*)::text FROM public.messages)
  UNION ALL
  SELECT 6, '⑥ messages インデックス', 'read_by の GIN インデックス',
         COALESCE(
           (SELECT string_agg(indexname::text, ', ')
            FROM   pg_indexes
            WHERE  schemaname='public' AND tablename='messages'
              AND  indexdef ILIKE '%gin%' AND indexdef ILIKE '%read_by%'),
           'なし（行数次第で追加を検討）')

) AS r
ORDER BY sec, item;


-- ================================================================
-- 実行後の判定
-- ================================================================
--
--   ① read_by / ARRAY / nullable=NO / default='{}'::text[] であること
--
--   ② 総行数 13 / read_by が空の行 0 / 8名以上入った行 13
--      → 成功。要素数は 8〜10 程度になるはず
--        （8名 + changed_by の顧客 + confirmed_by が admin なら重複排除される）
--
--   ③ 調査時と同じ（confirmed_by 設定済み 13 / NULL 0）
--      → backfill が confirmed_by を壊していないことの確認
--
--   ④ 両方 0 であること
--      → 1件でも出たら read_by の中身に不正な値が混入している
--
--   ⑥ messages 行数が数万を超えていて GIN が「なし」の場合
--      → Phase 2 に入る前に GIN 追加を検討する
--        （CREATE INDEX CONCURRENTLY を単独実行）
--
-- ================================================================
-- Phase 1 の残り
-- ================================================================
--   このファイルには含めていない（別ファイルで作成予定）:
--     - RPC mark_message_read(bigint)      … messages 1件を個別既読に
--     - RPC mark_change_log_read(uuid)     … order_change_logs 1件を個別既読に
--   計画書 §2-5 参照。クライアントからの read-modify-write による
--   lost update を防ぐため、既読の書き込み口はこの2本に閉じる。
-- ================================================================
