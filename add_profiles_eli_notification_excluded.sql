-- ================================================================
-- profiles に E-Li 通知除外フラグを追加
--   profiles.eli_notification_excluded
--
--   目的:
--     E-Li の通知システム（統合通知ベル・未読集計・backfill）の
--     対象外にするアカウントを指定する。
--     まず info@markan.co.jp（通知用システムアカウント）に適用する。
--
--   命名について:
--     profiles は E-Li / MK Daily / Seed Note の3システムで共有している。
--     各システムは自分の接頭辞付き列を使う規約になっているため、
--     それに従って eli_ 接頭辞を付ける。
--       seed-note  : profiles.seed_note_role / profiles.seed_note_excluded
--       mk-connect : profiles.mk_connect_role
--       E-Li       : profiles.eli_notification_excluded  ← 本カラム
--
--   既存 is_system との関係（★重要・両者は併存させる）:
--     is_system                 = 人間ではない（自動送信・通知用アカウント）
--                                 → メンション宛先候補から除外
--                                   add_mention_candidates_rpc.sql:105,124
--                                 → 本 migration では一切変更しない
--     eli_notification_excluded = 通知を受け取らない
--                                 → 通知ベル・未読集計・backfill から除外
--                                 → 本 migration で新設
--
--     info@markan.co.jp は両方に該当するため両方 true になる。
--     将来「人間だが通知は不要」（退職者・閲覧専用の管理者など）が
--     出た場合は eli_notification_excluded だけを true にする。
--     is_system を流用してしまうと、実在の担当者が
--     メンション候補からも消えるという副作用が出るため分離している。
--
--   ★ 実行順序:
--     このファイル → add_order_change_logs_read_by.sql の順で実行すること。
--     backfill が本カラムを参照するため、先に存在している必要がある。
--
--   使い方:
--     cat add_profiles_eli_notification_excluded.sql | pbcopy
--     → Supabase ダッシュボード > SQL Editor
-- ================================================================


-- ================================================================
-- STEP 1 : カラム追加
-- ================================================================
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS eli_notification_excluded boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.profiles.eli_notification_excluded IS
  'E-Li 通知除外フラグ。true = 統合通知ベル・未読集計・backfill の対象外。'
  'システムアカウント判定の is_system とは別概念（is_system はメンション候補の除外用）。'
  'profiles は3システム共有のため eli_ 接頭辞を付けている。';


-- ================================================================
-- STEP 2 : info@markan.co.jp を除外対象に設定
-- ================================================================
--   ★ 特定方法：メールで引き、UUID で照合する（二段構え）
--
--     更新条件はメールアドレス（auth.users 上で一意）。
--     そのうえで、引けた UUID が
--     7893dda8-bee1-4e6f-8cd4-3514ef5db2e4 と一致することを検証する。
--
--     UUID だけをハードコードして UPDATE すると、
--     アカウント再作成などで UUID が変わっていた場合に
--     「0件更新で静かに何も起きない」形で失敗する。
--     メールで引けば必ず現存アカウントに当たり、UUID 照合で
--     想定外を検知できる。
--
--     check_is_system.sql で三重一致を確認済み:
--       add_profiles_is_system.sql の UUID
--       = info@markan.co.jp
--       = 「インフォ さん」
--       role = manager
--
--   profiles 行が存在しない場合は例外を投げて中断する。
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_uid     uuid;
  v_updated int;
BEGIN
  SELECT u.id INTO v_uid
  FROM   auth.users u
  WHERE  lower(u.email) = 'info@markan.co.jp';

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'info@markan.co.jp が auth.users に存在しません。中断します。';
  END IF;

  -- ★ UUID 照合アサーション
  --   check_is_system.sql で以下の三重一致を確認済み:
  --     add_profiles_is_system.sql がハードコードする UUID
  --     = info@markan.co.jp
  --     = 「インフォ さん」
  --   メールで引いた結果がこの UUID と一致しない場合、
  --   アカウントが作り直された等の想定外が起きているため中断する。
  IF v_uid <> '7893dda8-bee1-4e6f-8cd4-3514ef5db2e4'::uuid THEN
    RAISE EXCEPTION
      'info@markan.co.jp の UUID が調査時と異なります'
      '（期待=7893dda8-bee1-4e6f-8cd4-3514ef5db2e4 / 実際=%）。'
      'アカウントが作り直された可能性があります。中断します。', v_uid;
  END IF;

  UPDATE public.profiles
  SET    eli_notification_excluded = true
  WHERE  id = v_uid;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated = 0 THEN
    RAISE EXCEPTION
      'info@markan.co.jp（id=%）の profiles 行が存在しません。'
      'profiles 行を作成してから再実行してください。', v_uid;
  END IF;

  RAISE NOTICE '─────────────────────────────────────';
  RAISE NOTICE 'info@markan.co.jp を通知除外に設定しました';
  RAISE NOTICE '  id            : %', v_uid;
  RAISE NOTICE '  更新された行数 : %', v_updated;
  RAISE NOTICE '─────────────────────────────────────';
END $$;


-- ================================================================
-- STEP 3 : 確認用 SELECT
-- ================================================================
SELECT * FROM (

  -- ① カラム定義
  SELECT 1 AS sec, '① カラム定義' AS section,
         column_name::text AS item,
         (data_type::text
          || ' / nullable=' || is_nullable::text
          || COALESCE(' / default=' || column_default::text, ''))::text AS value
  FROM   information_schema.columns
  WHERE  table_schema='public' AND table_name='profiles'
    AND  column_name='eli_notification_excluded'

  UNION ALL

  -- ② 除外対象になったアカウント一覧
  SELECT 2, '② 通知除外アカウント',
         COALESCE(u.email, '(auth.users に無し)')::text,
         format('name=%s / is_system=%s / role=%s',
                COALESCE(p.name, '(なし)'),
                p.is_system::text,
                COALESCE(u.raw_app_meta_data ->> 'role', '(なし)'))::text
  FROM   public.profiles p
  LEFT   JOIN auth.users u ON u.id = p.id
  WHERE  p.eli_notification_excluded = true

  UNION ALL

  -- ③ backfill 対象になる admin/manager（除外後）
  --    ★ここが7名になるはず
  SELECT 3, '③ backfill 対象（除外後）',
         u.email::text,
         format('%s / role=%s',
                COALESCE(p.name, '(profiles未登録)'),
                COALESCE(u.raw_app_meta_data ->> 'role', '(なし)'))::text
  FROM   auth.users u
  LEFT   JOIN public.profiles p ON p.id = u.id
  WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager')
    AND  COALESCE(p.eli_notification_excluded, false) = false

  UNION ALL

  -- ④ 件数サマリ
  SELECT 4, '④ 件数サマリ', 'admin/manager 総数',
         (SELECT count(*)::text FROM auth.users u
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager'))
  UNION ALL
  SELECT 4, '④ 件数サマリ', 'うち通知除外',
         (SELECT count(*)::text FROM auth.users u
          JOIN public.profiles p ON p.id = u.id
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND p.eli_notification_excluded = true)
  UNION ALL
  SELECT 4, '④ 件数サマリ', '★backfill 対象（除外後）',
         (SELECT count(*)::text FROM auth.users u
          LEFT JOIN public.profiles p ON p.id = u.id
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND COALESCE(p.eli_notification_excluded, false) = false)
  UNION ALL
  SELECT 4, '④ 件数サマリ', 'profiles 行が無い admin/manager（要注意）',
         (SELECT count(*)::text FROM auth.users u
          LEFT JOIN public.profiles p ON p.id = u.id
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND p.id IS NULL)

  UNION ALL

  -- ⑤ is_system と eli_notification_excluded の対応表
  --    2つのフラグが意図どおり分離できているかの確認
  SELECT 5, '⑤ フラグ対応表',
         COALESCE(u.email, p.id::text)::text,
         format('is_system=%s / eli_notification_excluded=%s',
                p.is_system::text,
                p.eli_notification_excluded::text)::text
  FROM   public.profiles p
  LEFT   JOIN auth.users u ON u.id = p.id
  WHERE  p.is_system = true
     OR  p.eli_notification_excluded = true

) AS r
ORDER BY sec, item;


-- ================================================================
-- 実行後の判定
-- ================================================================
--
--   ① eli_notification_excluded / boolean / nullable=NO / default=false
--
--   ② info@markan.co.jp が1件出ること
--
--   ③ 7名が並ぶこと（info@ が含まれていないこと）
--
--   ④ 総数8 / 除外1 / ★backfill 対象7 / profiles 未登録0
--      → 「profiles 未登録」が1以上なら要調査。
--        LEFT JOIN + COALESCE で false 扱いになるため除外はされないが、
--        管理者に profiles 行が無いこと自体が別の問題
--
--   ⑤ info@markan.co.jp が is_system=true / eli_notification_excluded=true
--      両方 true で並ぶこと。
--      他のアカウントが混ざっている場合は意図を確認する
--
--   → ④の★が 7 になったら add_order_change_logs_read_by.sql に進む
-- ================================================================
