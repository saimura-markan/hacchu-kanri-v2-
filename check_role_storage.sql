-- ================================================================
-- 【読み取り専用】Phase 1 backfill 前のロール格納場所 確認クエリ
--
--   目的:
--     docs/notification-bell-plan.md §2-4 ③(c) の backfill を流す前に、
--     admin/manager のロールが実際にどこに入っているかを確認する。
--
--       候補A: auth.users.raw_app_meta_data ->> 'role'  （= JWT の app_metadata）
--       候補B: auth.users.raw_user_meta_data ->> 'role' （= JWT の user_metadata）
--       候補C: profiles の何らかの列
--
--   確認が必要な理由（リポジトリ内の実装が一貫していない）:
--     - 大半の RLS は app_metadata を参照
--         add_order_change_logs.sql:37 / add_staff_table.sql:24 /
--         add_status_logs_table.sql:27 / add_site_history.sql:39 ほか
--     - add_cases_table.sql:82 は user_metadata を参照
--     - fix_schedule_history_rls.sql:12 は「どちらに設定していても動作」と
--       コメントした上で app/user の両方をチェックしている
--     - add_mention_candidates_rpc.sql:28-32 は
--       「profiles.role ではなく auth.users.raw_app_meta_data から判定」と明記
--     - CLAUDE.md は「user_metadata に設定」と記載（コードの読み取り先と食い違い）
--
--   ★ このファイルは SELECT のみ。UPDATE / INSERT / DELETE / DDL は一切含まない。
--     実行してもデータは変わらない。
--
--   使い方:
--     cat check_role_storage.sql | pbcopy
--     → Supabase ダッシュボード > SQL Editor に貼り付けて実行
--     → 結果は1つの表にまとまって出る（sec 列の順に読む）
-- ================================================================

SELECT * FROM (

  -- ────────────────────────────────────────────────────────────
  -- ① profiles の全カラム（他システムが追加した権限列がないか確認）
  --    E-Li / MK Daily / Seed Note は同一の auth.users / profiles を
  --    共有しているため、role 系の列が後から生えている可能性がある
  -- ────────────────────────────────────────────────────────────
  SELECT 1 AS sec, '① profiles カラム一覧' AS section,
         column_name::text AS item,
         (data_type::text || COALESCE(' / default=' || column_default::text, ''))::text AS value
  FROM   information_schema.columns
  WHERE  table_schema = 'public' AND table_name = 'profiles'

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ② 候補A: app_metadata の role 分布
  --    ここに admin / manager が並べば、計画書の SQL がそのまま使える
  -- ────────────────────────────────────────────────────────────
  SELECT 2, '② app_metadata の role 分布',
         COALESCE(raw_app_meta_data ->> 'role', '(未設定)')::text,
         (count(*)::text || ' 人')::text
  FROM   auth.users
  GROUP  BY 1, 2, 3

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ③ 候補B: user_metadata の role 分布
  --    こちらにしか入っていなければ backfill の WHERE 句を差し替える
  -- ────────────────────────────────────────────────────────────
  SELECT 3, '③ user_metadata の role 分布',
         COALESCE(raw_user_meta_data ->> 'role', '(未設定)')::text,
         (count(*)::text || ' 人')::text
  FROM   auth.users
  GROUP  BY 1, 2, 3

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ④ app と user で role が食い違っているアカウント
  --    0件なら「どちらを見ても同じ」＝安全。
  --    1件でも出たら、どちらを正とするかの判断が必要。
  -- ────────────────────────────────────────────────────────────
  SELECT 4, '④ app/user の食い違い',
         u.email::text,
         format('app=%s / user=%s',
                COALESCE(u.raw_app_meta_data  ->> 'role', '(なし)'),
                COALESCE(u.raw_user_meta_data ->> 'role', '(なし)'))::text
  FROM   auth.users u
  WHERE  COALESCE(u.raw_app_meta_data  ->> 'role', '')
    IS DISTINCT FROM
         COALESCE(u.raw_user_meta_data ->> 'role', '')

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑤ backfill の対象になる admin/manager 一覧（app_metadata 基準）
  --    ★ 件数と顔ぶれを必ず目視すること。
  --      ここに出た全員の UUID が read_by に入る（＝過去ログを既読扱い）。
  --      想定より多い / 退職者が混ざっている等があれば backfill を止める。
  -- ────────────────────────────────────────────────────────────
  SELECT 5, '⑤ backfill 対象 (app_metadata)',
         u.email::text,
         format('%s / role=%s / id=%s',
                COALESCE(p.name, '(profiles未登録)'),
                COALESCE(u.raw_app_meta_data ->> 'role', '(なし)'),
                u.id::text)::text
  FROM   auth.users u
  LEFT   JOIN public.profiles p ON p.id = u.id
  WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager')

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑥ 同上を user_metadata 基準でも出す（②③の結果次第で使う方を選ぶ）
  -- ────────────────────────────────────────────────────────────
  SELECT 6, '⑥ backfill 対象 (user_metadata)',
         u.email::text,
         format('%s / role=%s / id=%s',
                COALESCE(p.name, '(profiles未登録)'),
                COALESCE(u.raw_user_meta_data ->> 'role', '(なし)'),
                u.id::text)::text
  FROM   auth.users u
  LEFT   JOIN public.profiles p ON p.id = u.id
  WHERE  u.raw_user_meta_data ->> 'role' IN ('admin', 'manager')

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑦ order_change_logs の現状（backfill が何行に触るかの把握）
  -- ────────────────────────────────────────────────────────────
  SELECT 7, '⑦ order_change_logs 現状', '総行数',
         (SELECT count(*)::text FROM public.order_change_logs)
  UNION ALL
  SELECT 7, '⑦ order_change_logs 現状', 'confirmed_by IS NULL（＝現在の未確認）',
         (SELECT count(*)::text FROM public.order_change_logs WHERE confirmed_by IS NULL)
  UNION ALL
  SELECT 7, '⑦ order_change_logs 現状', 'confirmed_by 設定済み',
         (SELECT count(*)::text FROM public.order_change_logs WHERE confirmed_by IS NOT NULL)
  UNION ALL
  SELECT 7, '⑦ order_change_logs 現状', 'changed_by IS NULL（既読付与できない行）',
         (SELECT count(*)::text FROM public.order_change_logs WHERE changed_by IS NULL)
  UNION ALL
  SELECT 7, '⑦ order_change_logs 現状', 'distinct order_id 数',
         (SELECT count(DISTINCT order_id)::text FROM public.order_change_logs)
  UNION ALL
  SELECT 7, '⑦ order_change_logs 現状', '最古 changed_at',
         (SELECT COALESCE(min(changed_at)::text, '(0件)') FROM public.order_change_logs)
  UNION ALL
  SELECT 7, '⑦ order_change_logs 現状', '最新 changed_at',
         (SELECT COALESCE(max(changed_at)::text, '(0件)') FROM public.order_change_logs)

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑧ read_by カラムの存在確認（migration の冪等性チェック）
  --    order_change_logs 側は「なし」が想定どおり（Phase 1 未適用のため）
  -- ────────────────────────────────────────────────────────────
  SELECT 8, '⑧ read_by カラム', 'order_change_logs.read_by',
         COALESCE(
           (SELECT (data_type::text || COALESCE(' / default=' || column_default::text, ''))::text
            FROM information_schema.columns
            WHERE table_schema='public' AND table_name='order_change_logs'
              AND column_name='read_by'),
           'なし（Phase 1 未適用＝想定どおり）')
  UNION ALL
  SELECT 8, '⑧ read_by カラム', 'messages.read_by',
         COALESCE(
           (SELECT (data_type::text || COALESCE(' / default=' || column_default::text, ''))::text
            FROM information_schema.columns
            WHERE table_schema='public' AND table_name='messages'
              AND column_name='read_by'),
           'なし（想定外。要確認）')

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑨ messages.read_by の中身サンプル
  --    UUID 文字列が入っているか（過去にメール文字列混在の形跡あり:
  --    fix_read_by_uuid_cleanup.sql / fix_read_by_remove_self.sql）
  -- ────────────────────────────────────────────────────────────
  SELECT 9, '⑨ messages.read_by 中身', 'read_by が空でない行数',
         (SELECT count(*)::text FROM public.messages
          WHERE read_by IS NOT NULL AND array_length(read_by, 1) > 0)
  UNION ALL
  SELECT 9, '⑨ messages.read_by 中身', '@ を含む要素がある行数（メール混在の残骸）',
         (SELECT count(*)::text FROM public.messages
          WHERE EXISTS (SELECT 1 FROM unnest(COALESCE(read_by,'{}')) e WHERE e LIKE '%@%'))

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑩ 既存インデックス（GIN が必要かの判断材料）
  --    messages.read_by / order_change_logs.changed_at に
  --    インデックスが無ければ Phase 1 で追加する
  -- ────────────────────────────────────────────────────────────
  SELECT 10, '⑩ 既存インデックス', (tablename::text || ' : ' || indexname::text)::text,
         indexdef::text
  FROM   pg_indexes
  WHERE  schemaname = 'public'
    AND  tablename IN ('messages', 'order_change_logs')

) AS r
ORDER BY sec, item;


-- ================================================================
-- 結果の読み方 / 次のアクション
-- ================================================================
--
--   ②に admin / manager が並び、③が全員 (未設定) の場合
--     → 計画書 §2-4 ③(c) の SQL をそのまま使える（raw_app_meta_data 基準）
--
--   ③にしか admin / manager が居ない場合
--     → backfill の WHERE を raw_user_meta_data に差し替える
--
--   ②③の両方に居る & ④が0件
--     → どちらでも同じ。app_metadata 基準で統一する
--
--   ④が1件でも出た場合
--     → ★backfill を止める。どちらを正とするか決めてから進める
--
--   ①に role / *_role のような列があった場合
--     → 他システムの権限列。E-Li の判定には使わないが、
--       混同しないよう計画書に追記する
--
--   ⑤⑥の件数が想定と違う場合
--     → ★backfill を止める。対象者を確定させてから進める
--
--   ⑦の「confirmed_by IS NULL」の件数
--     → backfill 案A を流さなかった場合に、初日ベルに積まれる未読数。
--       この数字を見てから案A実行の是非を最終判断する
--
-- ================================================================
