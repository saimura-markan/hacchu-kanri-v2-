-- ================================================================
-- E-Li 工事受発注システム — read_by から「送信者自身の UUID」を除去
--
-- 【背景】
--   markReadBy / markChatRead が、自分が送信したメッセージにも
--   自分の UUID を read_by に追記していたため、
--   read_by に送信者自身が混入している。
--   その結果、
--     ・既読メンバーモーダルに送信者本人が表示される
--     ・「既読者0人」の判定が狂う
--   という不整合が発生していた。
--   アプリ側は修正済み（今後は送信者自身を追記しない）だが、
--   既存データには送信者 UUID が残っているため本 SQL で除去する。
--
--   ※ read_by は text[]、sender_id は uuid。比較は text へキャストして行う。
--   ※ このファイルは作成のみ。まだ実行しないでください。
-- ================================================================


-- ----------------------------------------------------------------
-- STEP 0: 現状確認（実行前にコメントを外して確認）
-- read_by に自分自身（sender_id）が入っている行を洗い出す
-- ----------------------------------------------------------------
-- SELECT id, order_id, sender_id, read_by
-- FROM messages
-- WHERE sender_id IS NOT NULL
--   AND read_by IS NOT NULL
--   AND sender_id::text = ANY(read_by);


-- ----------------------------------------------------------------
-- STEP 1: read_by から送信者自身の UUID を除去
--   array_remove は一致する全要素を除去する。
--   対象は「sender_id が read_by に含まれている行」のみ（無駄な更新を避ける）。
-- ----------------------------------------------------------------
UPDATE messages
SET read_by = array_remove(read_by, sender_id::text)
WHERE sender_id IS NOT NULL
  AND read_by IS NOT NULL
  AND sender_id::text = ANY(read_by);


-- ----------------------------------------------------------------
-- STEP 2: 結果確認（実行後にコメントを外して確認）
-- ----------------------------------------------------------------
-- SELECT COUNT(*) AS rows_with_self_in_readby
-- FROM messages
-- WHERE sender_id IS NOT NULL
--   AND read_by IS NOT NULL
--   AND sender_id::text = ANY(read_by);
-- 期待値: 0
