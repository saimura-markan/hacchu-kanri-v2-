-- ================================================================
-- 【読み取り専用】info@markan.co.jp の is_system 現在値の確認
--
--   目的:
--     通知システムからの除外方法（案A: is_system 流用 /
--     案B: eli_notification_excluded 新設）を決める前に、
--     現在の is_system の実データを確認する。
--
--   確認したいこと:
--     1. add_profiles_is_system.sql が実際に実行されたか
--        （カラムが存在するか / UPDATE が反映されているか）
--     2. UUID 7893dda8-bee1-4e6f-8cd4-3514ef5db2e4 が
--        本当に info@markan.co.jp なのか
--     3. is_system = true のアカウントが他にも居ないか
--     4. backfill 対象 8名のうち、どれが除外候補か
--
--   ★ SELECT のみ。データは変更されない。
--
--   使い方:
--     cat check_is_system.sql | pbcopy
--     → Supabase ダッシュボード > SQL Editor
-- ================================================================

SELECT * FROM (

  -- ────────────────────────────────────────────────────────────
  -- ① is_system カラムが存在するか（migration 実行済みか）
  -- ────────────────────────────────────────────────────────────
  SELECT 1 AS sec, '① is_system カラム' AS section,
         'profiles.is_system' AS item,
         COALESCE(
           (SELECT (data_type::text
                    || ' / nullable=' || is_nullable::text
                    || COALESCE(' / default=' || column_default::text, ''))::text
            FROM   information_schema.columns
            WHERE  table_schema='public' AND table_name='profiles'
              AND  column_name='is_system'),
           '★カラムが存在しない（add_profiles_is_system.sql 未実行）') AS value

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ② is_system = true のアカウント全件
  --    add_profiles_is_system.sql の UPDATE が効いていれば
  --    「インフォ さん」が1件出る
  -- ────────────────────────────────────────────────────────────
  SELECT 2, '② is_system = true の全件',
         COALESCE(u.email, '(auth.users に無し)')::text,
         format('name=%s / id=%s / role=%s',
                COALESCE(p.name, '(なし)'),
                p.id::text,
                COALESCE(u.raw_app_meta_data ->> 'role', '(なし)'))::text
  FROM   public.profiles p
  LEFT   JOIN auth.users u ON u.id = p.id
  WHERE  p.is_system = true

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ③ add_profiles_is_system.sql がハードコードしている UUID の実体
  --    このアカウントが本当に info@markan.co.jp かを確認する
  -- ────────────────────────────────────────────────────────────
  SELECT 3, '③ ハードコード UUID の実体',
         '7893dda8-bee1-4e6f-8cd4-3514ef5db2e4',
         COALESCE(
           (SELECT format('email=%s / name=%s / is_system=%s / role=%s',
                          COALESCE(u.email, '(なし)'),
                          COALESCE(p.name, '(なし)'),
                          p.is_system::text,
                          COALESCE(u.raw_app_meta_data ->> 'role', '(なし)'))::text
            FROM   public.profiles p
            LEFT   JOIN auth.users u ON u.id = p.id
            WHERE  p.id = '7893dda8-bee1-4e6f-8cd4-3514ef5db2e4'),
           '★該当なし（profiles にこの UUID が存在しない）')

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ④ info@markan.co.jp の実体（メールアドレスから直接引く）
  --    ③の UUID と一致するかを突き合わせる
  -- ────────────────────────────────────────────────────────────
  SELECT 4, '④ info@markan.co.jp',
         'メールから逆引き',
         COALESCE(
           (SELECT format('id=%s / name=%s / is_system=%s / role=%s',
                          u.id::text,
                          COALESCE(p.name, '(profiles未登録)'),
                          COALESCE(p.is_system::text, '(profiles未登録)'),
                          COALESCE(u.raw_app_meta_data ->> 'role', '(なし)'))::text
            FROM   auth.users u
            LEFT   JOIN public.profiles p ON p.id = u.id
            WHERE  lower(u.email) = 'info@markan.co.jp'),
           '★該当なし（このメールのアカウントが存在しない）')

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑤ backfill 対象 8名の一覧 + is_system の状態
  --    ★ここが本題。除外後に何名になるかを確定させる
  -- ────────────────────────────────────────────────────────────
  SELECT 5, '⑤ backfill 対象と is_system',
         u.email::text,
         format('%s / role=%s / is_system=%s',
                COALESCE(p.name, '(profiles未登録)'),
                COALESCE(u.raw_app_meta_data ->> 'role', '(なし)'),
                COALESCE(p.is_system::text, '(profiles未登録)'))::text
  FROM   auth.users u
  LEFT   JOIN public.profiles p ON p.id = u.id
  WHERE  u.raw_app_meta_data ->> 'role' IN ('admin', 'manager')

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑥ 除外後の件数シミュレーション
  --    「7名」になるかをここで確定させる
  -- ────────────────────────────────────────────────────────────
  SELECT 6, '⑥ 除外後の件数', 'admin/manager 総数',
         (SELECT count(*)::text FROM auth.users u
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager'))
  UNION ALL
  SELECT 6, '⑥ 除外後の件数', 'うち is_system = true',
         (SELECT count(*)::text FROM auth.users u
          JOIN public.profiles p ON p.id = u.id
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND p.is_system = true)
  UNION ALL
  SELECT 6, '⑥ 除外後の件数', 'うち info@markan.co.jp',
         (SELECT count(*)::text FROM auth.users u
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND lower(u.email) = 'info@markan.co.jp')
  UNION ALL
  -- ★これが本命。フラグに依存せず「info@ を除いた admin/manager 数」を直接数える。
  --   採用方針は eli_notification_excluded（新設列）だが、その列はまだ
  --   存在しないため、ここではメールアドレスで直接除外して 7 になるかを見る。
  SELECT 6, '⑥ 除外後の件数', '★info@ を除いた admin/manager 数（7 になるはず）',
         (SELECT count(*)::text FROM auth.users u
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND lower(u.email) <> 'info@markan.co.jp')
  UNION ALL
  -- 参考: is_system で除外した場合の数（案A を採っていた場合の値）
  --   info@ の is_system が false なら 8 のまま出る。それでも問題ない。
  SELECT 6, '⑥ 除外後の件数', '（参考）is_system で除外した場合',
         (SELECT count(*)::text FROM auth.users u
          LEFT JOIN public.profiles p ON p.id = u.id
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND COALESCE(p.is_system, false) = false)
  UNION ALL
  SELECT 6, '⑥ 除外後の件数', 'profiles 行が無い admin/manager（要注意）',
         (SELECT count(*)::text FROM auth.users u
          LEFT JOIN public.profiles p ON p.id = u.id
          WHERE u.raw_app_meta_data ->> 'role' IN ('admin','manager')
            AND p.id IS NULL)

  UNION ALL

  -- ────────────────────────────────────────────────────────────
  -- ⑦ 他システムの権限列（profiles 共有による影響範囲の把握）
  --    is_system を通知除外に流用した場合、
  --    他システムが同じ列を見ていないかの最終確認材料
  -- ────────────────────────────────────────────────────────────
  SELECT 7, '⑦ profiles の全カラム',
         column_name::text,
         data_type::text
  FROM   information_schema.columns
  WHERE  table_schema='public' AND table_name='profiles'

) AS r
ORDER BY sec, item;


-- ================================================================
-- 結果の読み方
-- ================================================================
--
--   ③と④の id が一致
--     → ハードコード UUID = info@markan.co.jp で確定
--
--   ④の is_system = true
--     → add_profiles_is_system.sql は実行済み。既にメンション候補から
--       除外されている。案A なら追加の UPDATE は不要
--
--   ④の is_system = false
--     → migration は未実行、または UPDATE だけ流れていない。
--       案A を採る場合はここを true にする UPDATE が必要
--
--   ⑥の「★is_system 除外後」が 7
--     → backfill 対象 7名で確定
--
--   ⑥の「profiles 行が無い admin/manager」が 1以上
--     → ★要注意。COALESCE(p.is_system, false) で false 扱いになるため
--       除外されないが、そもそも profiles 未登録の管理者が居ること自体が
--       別の問題。backfill 前に確認する
--
--   ⑦に eli_* / notification 系の列が既にあれば
--     → 案B の列名を決める際に重複を避ける
--
-- ================================================================
