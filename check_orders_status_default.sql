-- ================================================================
-- E-Li 顧客メール通知 第2段階（受付・キャンセル・日程相談中）
--   STEP 0 : 事前確認
--
--   ★ このファイルは SELECT のみ。DB を一切変更しない。
--     安心して本番の SQL Editor で流してよい。
--
--   使い方:
--     ★ 全部まとめて貼らないこと。
--       Supabase の SQL Editor は複数文を流すと「最後の SELECT の結果」しか
--       表示しない。0-1〜0-5 を1つずつコピーして個別に実行する。
--       （2026-08-03 実際にこれで 0-1〜0-4 の結果を取り逃がした）
--
--   実行結果（2026-08-03）:
--     0-5 … eli_users=15 / name_empty=0 / name_has_at=0 /
--            name_ascii_only=0 / name_japanese=15
--            → 全員実名。「mikanq1031様」問題は実在しない。
--              宛名フォールバックは新規ユーザー向けの保険として実装のみ行う。
-- ================================================================


-- ----------------------------------------------------------------
-- 0-1. orders の列定義と「status の DB 既定値」
-- ----------------------------------------------------------------
--   ★これが本題。
--   発注フォームの INSERT（index.html:3366）は status を指定していない。
--   4534 / 4583 の別経路だけが '調整中' を明示している。
--   したがって既定値が何かで、受付メールの expectedStatus ガードが
--   機能するかどうかが決まる。
--
--   期待する結果:  status の column_default が '調整中'::text
--   これ以外だった場合（NULL・別の値）は Edge Function 側の
--   expectedStatus をその値に合わせる。要相談。
SELECT column_name,
       data_type,
       column_default,
       is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'orders'
  AND  column_name IN ('id','user_id','status','deleted_at','case_id','company_id')
ORDER  BY column_name;


-- ----------------------------------------------------------------
-- 0-2. 実データ上のステータス分布
-- ----------------------------------------------------------------
--   既定値の宣言と実態が合っているかの裏取り。
--   AD_STATUS_LIST（index.html:6610）にない値が混ざっていないかも見る。
SELECT status, count(*) AS cnt
FROM   public.orders
WHERE  deleted_at IS NULL
GROUP  BY status
ORDER  BY cnt DESC;


-- ----------------------------------------------------------------
-- 0-3. orders に現在ぶら下がっているトリガー
-- ----------------------------------------------------------------
--   期待: trg_eli_notify_schedule_fixed が1本。
--   これを汎用関数 eli_notify_event() に張り替えるため、
--   事前に「他に何が付いているか」を確定させておく。
--   知らないトリガーが出てきたら、張り替え前に必ず確認する。
SELECT tgname,
       pg_get_triggerdef(oid) AS definition
FROM   pg_trigger
WHERE  tgrelid = 'public.orders'::regclass
  AND  NOT tgisinternal
ORDER  BY tgname;


-- ----------------------------------------------------------------
-- 0-4. 「1発注で orders が複数行になる」実態
-- ----------------------------------------------------------------
--   index.html:3365 の for (const sch of schedules) により、
--   複数日程の発注は case_id が同じ orders 行を複数生成する。
--   受付メールの重複抑止（eli_email_sent の UNIQUE）が
--   本当に必要かを実データで確認する。
--
--   multi_order_cases が 0 より大きければ、抑止は必須。
--   null_case_orders は dedup_key を COALESCE(case_id, id::text) に
--   フォールバックさせる対象の件数。
SELECT
  (SELECT count(*)
     FROM (SELECT case_id
             FROM   public.orders
             WHERE  case_id IS NOT NULL AND deleted_at IS NULL
             GROUP  BY case_id
             HAVING count(*) > 1) t)                    AS multi_order_cases,
  (SELECT max(c)
     FROM (SELECT count(*) AS c
             FROM   public.orders
             WHERE  case_id IS NOT NULL AND deleted_at IS NULL
             GROUP  BY case_id) t2)                     AS max_orders_per_case,
  (SELECT count(*) FROM public.orders
     WHERE case_id IS NULL AND deleted_at IS NULL)      AS null_case_orders;


-- ----------------------------------------------------------------
-- 0-5. 宛名フォールバックの実態（★件数のみ。氏名の実値は出さない）
-- ----------------------------------------------------------------
--   profiles は E-Li / MK Daily / Seed Note の3システム共有のため、
--   E-Li に発注のあるユーザーだけに絞って数える。
--
--   name_empty      … 「お客様」に落とす対象
--   name_has_at     … メールアドレスがそのまま入っている（要フォールバック）
--   name_ascii_only … 英数字のみ＝メールの @ 前が仮名として入った疑い
--                     （例: mikanq1031）。要フォールバック
--   name_japanese   … 日本語を含む＝実名とみなしてそのまま使う
--
--   ★ 氏名そのものは SELECT しない。ログや画面に顧客名を残さないため。
SELECT
  count(*)                                                        AS eli_users,
  count(*) FILTER (WHERE p.name IS NULL OR btrim(p.name) = '')    AS name_empty,
  count(*) FILTER (WHERE p.name LIKE '%@%')                       AS name_has_at,
  count(*) FILTER (WHERE p.name ~ '^[A-Za-z0-9._%+-]+$')          AS name_ascii_only,
  count(*) FILTER (WHERE p.name ~ '[ぁ-んァ-ヶ一-龥]')             AS name_japanese
FROM   public.profiles p
WHERE  EXISTS (SELECT 1 FROM public.orders o WHERE o.user_id = p.id);
