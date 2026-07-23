-- ================================================================
-- E-Li 工事受発注システム — messages.read_by の email/UUID 統一クリーンアップ
--
-- 【背景・調査結果】
--   read_by（text[]）への書き込みは2系統ある:
--     (A) アプリJS（顧客 ChatScreen / 管理 markChatRead）
--         → user.id（UUID）を append                … 正
--     (B) RPC mark_messages_read(p_order_id, p_email)
--         → user.email を append（管理者がチャットタブを開いた時）… 不整合
--   一方、未読・メンション件数の判定はすべて UUID で行っている:
--         .not('read_by', 'cs', '{<user.id>}')
--   → RPC が入れた email 要素は「どのクエリからも参照されない不活性データ」。
--     未読カウントの正誤には影響しないが、read_by に email が滞留する。
--   → profiles.email は全ユーザー NULL のため、そもそも email 経由の
--     既読管理は成立しておらず、実際の既読反映は UUID 系統(A)が担っている。
--
-- 【移行要否の判断】
--   ・正誤面では移行不要（消費側は UUID のみ参照するため email はノイズ）。
--   ・ただしデータ衛生・将来の混乱防止のため、以下の任意クリーンアップを推奨:
--       1. read_by から UUID形式でない要素（＝email）を除去
--       2. アプリ側で RPC 呼び出し(index.html)を撤去した後、
--          冗長になった mark_messages_read 関数を DROP
--
-- 【重要・実行順序】
--   本ファイルの STEP 1 は安全に実行可能（UUIDのみ残す）。
--   STEP 2（関数 DROP）は、index.html の
--     sb.rpc('mark_messages_read', ...) 呼び出しを削除・デプロイした後に
--     実行すること（先に DROP すると既存アプリが呼び出しエラーになる）。
--
--   ※ このファイルは作成のみ。まだ実行しないでください。
-- ================================================================


-- ----------------------------------------------------------------
-- STEP 0: 現状確認（実行前にコメントを外して確認）
-- ----------------------------------------------------------------
-- read_by に UUID形式でない要素（email等）を含む行を洗い出す
-- SELECT id, order_id, read_by
-- FROM messages
-- WHERE read_by IS NOT NULL
--   AND EXISTS (
--     SELECT 1 FROM unnest(read_by) AS e
--     WHERE e !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
--   );


-- ----------------------------------------------------------------
-- STEP 1: read_by を UUIDのみに正規化（email要素を除去）
--   ・UUID形式の要素だけを残して配列を再構築
--   ・全要素が除去された場合は空配列 '{}' にする
--   ・非UUID要素を含む行だけを対象（無駄な更新を避ける）
-- ----------------------------------------------------------------
UPDATE messages
SET read_by = COALESCE(
  (
    SELECT array_agg(e)
    FROM unnest(read_by) AS e
    WHERE e ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ),
  '{}'
)
WHERE read_by IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM unnest(read_by) AS e
    WHERE e !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  );


-- ----------------------------------------------------------------
-- STEP 2: 冗長になった RPC の削除
--   ※ 先に index.html の sb.rpc('mark_messages_read', ...) 呼び出しを
--     撤去・本番デプロイしてから実行すること。
--   既読反映は UUID を append する markChatRead / markReadBy（アプリJS）が
--   担うため、この関数は不要。
-- ----------------------------------------------------------------
-- DROP FUNCTION IF EXISTS public.mark_messages_read(text, text);


-- ----------------------------------------------------------------
-- （代替案）RPC を残す場合は UUID 版に作り替える
--   一括既読を DB 側でまとめて行いたい場合のみ。採用するなら STEP 2 の
--   DROP は行わず、アプリ側の呼び出しを p_uid（UUID）版に差し替える。
-- ----------------------------------------------------------------
-- CREATE OR REPLACE FUNCTION public.mark_messages_read(p_order_id text, p_uid uuid)
-- RETURNS void
-- LANGUAGE sql
-- SECURITY DEFINER
-- SET search_path = public, pg_temp
-- AS $$
--   UPDATE public.messages
--   SET read_by = array_append(COALESCE(read_by, '{}'), p_uid::text)
--   WHERE order_id = p_order_id
--     AND NOT (p_uid::text = ANY(COALESCE(read_by, '{}')));
-- $$;


-- ----------------------------------------------------------------
-- STEP 3: クリーンアップ結果の確認（実行後にコメントを外して確認）
-- ----------------------------------------------------------------
-- SELECT COUNT(*) AS rows_with_non_uuid
-- FROM messages
-- WHERE read_by IS NOT NULL
--   AND EXISTS (
--     SELECT 1 FROM unnest(read_by) AS e
--     WHERE e !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
--   );
-- 期待値: 0
