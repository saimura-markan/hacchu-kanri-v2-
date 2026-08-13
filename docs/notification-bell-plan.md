# E-Li 全通知統合ベル 実装計画書

**対象ファイル**: `index.html`（単一HTML / Babel standalone JSX、10,760行 / 558KB）
**作成日**: 2026-07-28
**ステータス**: Phase 0（下地・2026-07-28）/ Phase 1（DB migration・2026-07-29）完了。
次は §11「次回の再開地点」を参照（`get_mention_candidates` 調査 → §13 画像最適化 → Phase 2）。
§2-4 / §2-5 のコード片は**当初案**であり、実データを見て変更した点がある。
実装の正はコミット済みの SQL ファイルと §11 の記録。
**要決定事項**: §8 の5点すべてユーザー承認済み（本文に反映済み）

---

## 0. ゴールと非ゴール

### ゴール

1. メンション未読・チャット未読・`order_change_logs` の変更通知を **1つのベルアイコン** に集約
2. ベルクリックで **通知一覧パネル** を開く
3. 各通知クリックで **該当案件の該当箇所**（チャット→該当メッセージ、変更→該当変更行）まで到達
4. **その通知だけが個別に既読**になる
5. 管理者側・顧客側の両方

### 非ゴール（スコープ外・Phase 5 以降の拡張余地として記録）

- `status_logs` / `schedule_history` / `site_history` のフィード統合
- ブラウザプッシュ通知・メール通知
- 通知の削除・アーカイブ機能
- リアルタイム購読への切替（3秒ポーリングを維持）

### 顧客側スコープに関する重要な前提

`order_change_logs` は**顧客自身が書き込むテーブル**（`index.html:4413`, `4498`）です。
したがって顧客側ベルの通知源は **メンション未読・チャット未読のみ** になります。

顧客にとって意味のある「変更されました」通知は `status_logs` / `schedule_history` 側にあり、
これは Phase 5 で同じフィード構造に流し込む設計にしておきます。
（データ構造を最初から `type` 拡張可能にする理由）

---

## 1. 統合通知フィードのデータ構造

### 1-1. クライアント側の正規化オブジェクト

DB のテーブル形状に依存しない、UI が唯一参照する正規形を定義します。

```
NotificationItem {
  key        : string        // 一意キー。"msg:1234" / "chg:uuid" 形式
                             //   → React key・重複排除に使用
  type       : 'mention' | 'chat' | 'change'
  orderId    : string        // orders.id（text）— 案件解決の唯一のキー
  messageId  : number | null // messages.id（bigint）。type='chat'|'mention' のとき必須
  logId      : string | null // order_change_logs.id（uuid）。type='change' のとき必須
  createdAt  : string        // ISO文字列
                             //   messages.created_at / order_change_logs.changed_at
  read       : boolean       // 自分にとっての既読

  // ── 表示用（遅延取得。§7-2 の二段構え参照）──
  actorName  : string        // sender_name / changed_by の氏名
  excerpt    : string        // 本文抜粋 or "現場担当者: A → B"
  siteName   : string        // orders から JS join
}
```

### 1-2. type の決定ロジック

| type | 判定 | 由来テーブル |
|---|---|---|
| `mention` | `mentions` 配列に自分の UUID（旧データは氏名文字列）を含む | `messages` |
| `chat` | 上記以外の未読メッセージ | `messages` |
| `change` | 未読の変更ログ | `order_change_logs` |

管理者側の現行判定（`index.html:10023-10037`）をそのまま踏襲し、
旧データ救済（`m.mentions?.includes(myName)`）も維持します。

### 1-3. 既読状態の判定

| type | 未読条件 |
|---|---|
| `mention` / `chat` | `messages.read_by` に自分の UUID が**含まれない** かつ `sender_id != 自分` |
| `change` | `order_change_logs.read_by` に自分の UUID が**含まれない** かつ `changed_by != 自分`（← **新設カラム**、§2） |

### 1-4. ソートと上限

- `createdAt` 降順
- **`.limit(100)` を必ず付ける**
  （現行の未読集計はリミットなしで全未読を舐めており、案件増加で線形悪化する。ここは改善になる）
- 100件超は「もっと見る」で追加取得、または「99+」表示で打ち止め

### 1-5. 現行の潜在バグ（フィード化のついでに直す）

管理者側の未読集計（`index.html:10011-10037`）は `messages` に対して
**order_id の絞り込みが一切ない**ため、削除済み（`deleted_at` が入った）案件の未読もカウントされます。

一方 `orders` は `deleted_at is null` でしか取得していない（`index.html:9997`）ため、
**バッジは立つが対応する案件カードが一覧に存在しない**状態が起こり得ます。

→ フィード構築時に **`orders` state に存在する `order_id` のみ通す**フィルタを噛ませる。
　 到達不能な通知を作らないためにも必須。

---

## 2. `order_change_logs` の per-user 既読

### 2-1. 現状の問題

| カラム | 現状の意味 | 問題 |
|---|---|---|
| `confirmed_by uuid` | 誰か1人が確認したら埋まる | **グローバル1回**。A さんが確認すると B さんのバッジも消える |
| `confirmed_at` | 確認時刻 | 同上 |

既読化は `handleConfirmChanges()`（`index.html:7477-7488`）が**案件単位で一括**更新。
個別既読という概念がありません。

### 2-2. 方針：`read_by` を追加し、`confirmed_by` と意味を分離する

| カラム | 新しい意味 | 使う場所 |
|---|---|---|
| `read_by`（新設） | **個人の既読**。「その人が通知を見た」 | ベルの未読判定・通知フィード |
| `confirmed_by` / `confirmed_at`（既存維持） | **業務上の確認**。「組織として内容を確認済み」 | 詳細画面の `✅確認済` バッジ・「確認済みにする」ボタン（`index.html:8415-8424`, `8437-8440`） |

この分離により、既存 UI（`index.html:8409-8444`）は**一切変更せずそのまま動きます**。

### 2-3. 型の決定：`text[]`（承認済み）

`messages.read_by` は `text[]`（`alter_messages_for_chat.sql:11`）で、中身は UUID 文字列です。
`order_change_logs.read_by` を `uuid[]` にすると、同じ「read_by に自分がいるか」の判定コードが
2系統に分かれます（配列生成・PostgREST の `cs` フィルタ・backfill SQL すべて）。

→ **`text[]` で統一**。`.not('read_by','cs','{uid}')` のクエリ文字列がそのまま使い回せます。

> 補足：`fix_read_by_uuid_cleanup.sql` / `fix_read_by_remove_self.sql` の存在から、
> `messages.read_by` には過去メール文字列と UUID が混在していた形跡があります。
> 新カラムは最初から UUID のみを入れる規約とし、書き込み口を RPC 1本に絞ることで再発を防ぎます（§2-5）。

### 2-4. Migration 案（**未実行**）

`add_order_change_logs_read_by.sql` として新規作成する想定：

```sql
-- ================================================================
-- order_change_logs に per-user 既読カラムを追加
-- ※ confirmed_by（業務上の確認）とは意味を分離する
--    read_by      = 個人が通知を見た
--    confirmed_by = 組織として内容を確認した（既存のまま）
-- ================================================================

-- ① カラム追加
alter table public.order_change_logs
  add column if not exists read_by text[] not null default '{}';

-- ② インデックス
--    read_by の containment 検索を seq scan にしないため GIN
create index if not exists order_change_logs_read_by_idx
  on public.order_change_logs using gin (read_by);
--    フィードのソート・limit 用
create index if not exists order_change_logs_changed_at_idx
  on public.order_change_logs (changed_at desc);

-- ③ backfill
--    (a) 既に confirmed_by が入っている行は、その人を既読扱いにする
update public.order_change_logs
  set read_by = array_append(read_by, confirmed_by::text)
  where confirmed_by is not null
    and not (confirmed_by::text = any(read_by));

--    (b) 自分が書いた変更は自分にとって既読
update public.order_change_logs
  set read_by = array_append(read_by, changed_by::text)
  where changed_by is not null
    and not (changed_by::text = any(read_by));

--    (c) 【決定：案A】移行日以前の行は全 admin/manager を既読扱いにする
--        → 運用初日にベルが3桁になる事故を防ぐ
update public.order_change_logs
  set read_by = (
    select array(
      select distinct e from unnest(
        read_by || array(
          select u.id::text from auth.users u
          where (u.raw_app_meta_data ->> 'role') in ('admin','manager')
        )
      ) e
    )
  )
  where changed_at < now();   -- ← 実行時点より前の全行
```

> **③(c) の実行前チェック**：`auth.users.raw_app_meta_data ->> 'role'` で
> admin/manager が正しく引けるか、`select` で件数を目視確認してから update を流すこと。
> ロールの格納場所が `profiles` 側の可能性もあるため、Phase 1 の最初に確認する。

**`messages` 側にも同じ検討が要ります**：
`messages.read_by` に GIN インデックスが存在するか未確認です（`add_messages_index.sql` は `order_id` のみ）。
3秒ポーリングで `cs` 検索を回している以上、無ければ追加すべきです。
Phase 1 で `pg_indexes` を確認してから判断します。

### 2-5. 個別既読の RPC（推奨）

クライアントから `read_by` を read-modify-write する現行方式（`index.html:10467-10471`）は、

- 同時実行で追記が消える（lost update）
- UPDATE ポリシーが全カラムに開いているため、誤って `confirmed_by` を書き換えるリスク

があります。個別既読は **SECURITY DEFINER の RPC 2本**に閉じるのが安全です。

```sql
-- ================================================================
-- 通知の個別既読 RPC
-- ================================================================

-- messages 1件を自分の既読にする
create or replace function public.mark_message_read(p_message_id bigint)
returns void language sql security definer as $$
  update public.messages
    set read_by = array_append(coalesce(read_by,'{}'), auth.uid()::text)
  where id = p_message_id
    and not (auth.uid()::text = any(coalesce(read_by,'{}')));
$$;

-- order_change_logs 1件を自分の既読にする
create or replace function public.mark_change_log_read(p_log_id uuid)
returns void language sql security definer as $$
  update public.order_change_logs
    set read_by = array_append(coalesce(read_by,'{}'), auth.uid()::text)
  where id = p_log_id
    and not (auth.uid()::text = any(coalesce(read_by,'{}')));
$$;
```

これにより `order_change_logs` の UPDATE ポリシー
（現行 admin/manager 限定、`add_order_change_logs.sql:34-37`）を**広げずに**、
顧客・staff も既読を打てるようになります。

なお既存の `mark_messages_read(p_order_id, p_email)`（`alter_messages_for_chat.sql:15-24`）は
**email ベース・案件単位**の旧仕様で、現行コードからは呼ばれていません。Phase 5 で削除候補。

### 2-6. 移行時の一斉未読 →【決定：案A 全既読化】

`read_by` を追加した瞬間、`confirmed_by IS NULL` の過去ログが**全部未読としてベルに積まれます**。

| 案 | 内容 | 判断 |
|---|---|---|
| **A** | 移行実行日より前の行は、全 admin/manager の UUID を `read_by` に流し込んで既読化 | **採用** |
| B | 直近7日分だけ未読として残す | 不採用 |
| C | 何もしない | 不採用 |

→ §2-4 の ③(c) に反映済み。

---

## 3. ベル UI の配置と一覧パネルの構造

### 3-1. 管理者側

**ベルの配置**：サイドバー（`index.html:10527-10583`、width 60px）の 📋 の直下に 🔔 を追加。

**既存バッジの整理（決定：移動 + title 付与）**：

現在 🗑️ の直下にある `{adjCount+soudCount}` バッジ（`index.html:10549-10555`）は
「調整中＋相談中の件数」であり未読ではありません。ゴミ箱の通知だと誤読される位置にあります。

- 🔔 の**上**（📋 の直後）に移動し、`title="要対応（調整中・相談中）"` を付与
- 値・ロジックは変更しない（`index.html:10479-10480` はそのまま）
- ベルに統合はしない（性質が違うため）
- 🔔 のバッジは別に持つ（未読フィード件数）

**パネル**：サイドバー直右のドロワー

```
position: fixed; left: 60px; top: 0; width: 360px; height: 100vh;
background: #fff; border-right: 2px solid grayL;
box-shadow: 4px 0 20px rgba(0,0,0,0.12); z-index: 150;
```

`CompanyPanel` / `StaffPanel`（`index.html:10617-10618`）と z-index 帯を揃え、
同時に開かない制御を入れます。背面クリック（透明オーバーレイ）で閉じる。

### 3-2. 顧客側

**ベルの配置**：`HistoryApp` のトップバー、ログアウトボタン（`index.html:5899`）の左に 🔔。

**既存の右下 E-Li 吹き出しの転換**：

「新しいメッセージがあるよ！」（`index.html:6086-6096`）は現状クリックしても閉じるだけです。
これを **ベルパネルを開くトリガー**に転換します（`onClick={()=>setShowNotifPanel(true)}`）。
導線が増えるだけで既存の見た目は維持。

**パネル**：モバイル前提のため**全画面ボトムシート**。
既存の案件ピッカーシート（`index.html:5926-`）と同じオーバーレイ構造を踏襲し、CSS の重複を避けます。

### 3-3. パネル内部構造（管理者・顧客共通コンポーネント）

```
┌──────────────────────────────────────┐
│ 🔔 通知  (未読 N)        [すべて既読] [×] │  ← ヘッダー固定
├──────────────────────────────────────┤
│ [すべて] [@メンション] [💬 チャット] [🔔 変更] │  ← フィルタチップ
├──────────────────────────────────────┤
│ ●  🔴 @メンション                          │
│    ○○ビル 3F  ·  佐藤                      │  ← 案件名（現場名）+ 送信者
│    「@田中 明日の資材の件ですが…」            │  ← 抜粋（60字で切る）
│    12分前                                  │
├──────────────────────────────────────┤
│    💬 チャット                             │  ← 既読は左ドット無し・薄色
│    △△マンション  ·  お客様                  │
│    「日程変更をお願いできますか」              │
│    1時間前                                  │
├──────────────────────────────────────┤
│ ●  🔔 変更                                │
│    ××邸  ·  現場担当者                      │
│    山田 太郎 → 鈴木 花子                     │
│    昨日 15:30                              │
└──────────────────────────────────────┘
                 ↓ スクロール
            [ もっと見る ]        ← 100件超のとき
```

- **色の規約は既存を踏襲**：
  メンション `#e63946` / チャット未読 `#f07800` / 変更 `#1a5fbf`（`index.html:7172-7188`）
- 未読行は左に赤ドット + 背景 `#fffaf5`、既読行は白背景 + 文字色 `C.gray`
- 空状態：「新しい通知はありません」＋ 📭（既存の空状態 `index.html:7285-7288` と同じ意匠）
- 「すべて既読」は**確認ダイアログ付き**（誤爆すると取り返しがつかない）
- 相対時刻（"12分前"）はローカル計算。`useTimer()`（既存）に相乗りして再描画

### 3-4. 一覧カードのバッジとの整合

`AdOrderCard` のバッジ（`index.html:7163-7190`）と `HiOrderCard`（`index.html:3715-3728`）は、
**同じフィード配列から `order_id` 別に集計した数**を表示するように差し替えます。

```
unreadCounts    = feed.filter(n => !n.read && n.type==='chat')    → order_id別 count
mentionCounts   = feed.filter(n => !n.read && n.type==='mention') → order_id別 count
changeLogCounts = feed.filter(n => !n.read && n.type==='change')  → order_id別 count
```

これにより **ベルとカードバッジが自動的に同期**します。
個別既読を打てば両方が同時に1減る。二重管理の余地を残しません。

`siteChangeCounts`（`site_history` 由来、`index.html:10040-10045`）は今回スコープ外なので現行維持。

---

## 4. クリック遷移の共通化

### 4-1. 単一エントリポイント `openNotification(n)`

管理者版・顧客版でそれぞれ1つずつ定義し、この関数以外から遷移させません。

```
openNotification(n):
  1. markOneRead(n)          ← 楽観更新 + RPC（await しない。UI を止めない）
  2. setShowNotifPanel(false)
  3. 案件を開く
       管理者: setSelected(orderFromState(n.orderId))
       顧客  : setDetailOrder(orderFromState(n.orderId))
  4. タブ / 画面を決める
       type='change'            → 管理者: initialTab='detail' / 顧客: screen='detail'
       type='chat' | 'mention'  → 管理者: initialTab='chat'   / 顧客: screen='chat'
  5. setScrollTarget({
       kind:    n.type==='change' ? 'log' : 'msg',
       id:      n.logId ?? n.messageId,
       orderId: n.orderId
     })
```

`orderFromState()` が null（削除済み・未取得）の場合はトーストを出して遷移しない。
§1-5 のフィルタで基本的に発生しませんが、レース対策として残します。

### 4-2. スクロール受け側（共通ロジック）

`scrollTarget` を上位 state に置き、受け側
（管理者=`DetailPanel`、顧客=`ChatScreen` / `DetailScreen`）が消費します。

```
useEffect 発火条件: scrollTarget && scrollTarget.orderId === 現在の order.id
  ↓
① ロード完了待ち
   kind='msg' : chats[orderId] が undefined の間は何もしない
                （既存規約 index.html:10103）
   kind='log' : changeLogs が空配列かつ未取得フラグの間は待つ
                （index.html:7440-7446）
  ↓
② DOM 探索
   el = document.querySelector(`[data-msg-id="${id}"]`)
      / document.querySelector(`[data-log-id="${id}"]`)
  ↓
③ 見つかった → el.scrollIntoView({ behavior:'smooth', block:'center' })
            → ハイライト（§4-3）
            → setScrollTarget(null)   ← 消費済みにする
  ↓
④ 見つからない → requestAnimationFrame でリトライ
   最大 20フレーム（約 330ms）× 5回 = 上限 ~1.5秒でギブアップし setScrollTarget(null)
   （React の再描画完了を待つため。setTimeout 固定値より確実）
```

**リトライ上限は必須**です。
無限リトライにすると、削除済みメッセージを指す通知が永久ループになります。

### 4-3. ハイライト演出

既存の `<style>` ブロック（管理者は `index.html:10509-10515`、顧客側は別途）に keyframes を1つ追加：

```css
@keyframes notifFlash {
  0%   { box-shadow: 0 0 0 0 rgba(230,57,70,0.55); background: #fff3f0; }
  100% { box-shadow: 0 0 0 12px rgba(230,57,70,0);  background: transparent; }
}
```

対象要素に 1.6秒だけ適用して自動で外す。
既存の `urgentPulse` / `msgIn` と同じ流儀なので追加コストはほぼゼロです。

### 4-4. `bottomRef` の自動最下部スクロールとの競合 ⚠️ 最重要

現在、チャットは `chats` / `messages` が変わるたびに**無条件で最下部へ飛びます**
（管理者 `index.html:7370`、顧客 `index.html:5199`）。

→ `scrollTarget` が立っている間はこの自動スクロールを**抑止する**必要があります。
　 `useEffect` の先頭に `if (scrollTargetRef.current) return;` を追加。

これを忘れると「該当メッセージへ飛んだ直後に最下部へ引き戻される」という
最も起きやすい不具合になります。**実装時の最重要注意点**。

---

## 5. 必要な下準備（Phase 0 で先行実施）

先の調査で判明した制約5点への対応が、そのまま下準備リストになります。

| # | 制約 | 対応 | 該当箇所 |
|---|---|---|---|
| 1 | **DetailPanel の tab が内部 state** | `DetailPanel` に `initialTab` prop を追加。`useEffect([order?.id, initialTab])` で `setTab(initialTab \|\| 'detail')`。完全な lift up（`tab`/`onTabChange` 化）は差分が大きいので採らない | `index.html:7340`（state 定義）、`7752-7756`（タブボタン）、`10608-10614`（呼び出し） |
| 2 | **メッセージに DOM 識別子なし** | バブル外側 div に `data-msg-id={msg.id}` を付与。変更履歴行に `data-log-id={l.id}` を付与。`React.Fragment` の `key` は DOM に出ないので**別途必要** | 管理者バブル `index.html:8683-8686`、顧客バブル `index.html:5520` 付近、変更履歴行 `index.html:8425` |
| 3 | **チャット遅延ロード** | `chats[id] === undefined` = 未ロード、という既存規約を「ロード待ちガード」として明文化（§4-2 ①）。加えて `scrollTargetRef`（ref）で「消費済み」を管理し、二重発火を防ぐ | `index.html:10101-10108` |
| 4 | **通知集計に message_id なし** | `select` に `id` と `created_at` を追加。§7-2 の二段構えに従い、ポーリング時は軽量列のみ | 管理者 `index.html:10012-10014`, `10025-10028`, `10048-10050` / 顧客 `index.html:5745-5749`, `5775-5779` |
| 5 | **order_change_logs が per-user 既読でない** | `read_by text[]` 追加 + RPC（§2） | `add_order_change_logs.sql` |

### 追加の下準備

6. **フィード構築関数の切り出し**
   `buildNotificationFeed({ msgRows, logRows, orders, uid, myName })` を純関数として定義。
   管理者・顧客で共有し、テストしやすくする。

7. **`markOneRead(n)` の実装**
   楽観更新（フィード配列内の1件を `read:true`）→ RPC 呼び出し → 失敗時のロールバック。

8. **案件名の解決**
   `orders` state から `order_id → site / company` を JS join。
   `orders` にない場合は「（削除済み案件）」表示にせず、§1-5 のフィルタで除外。

---

## 6. 実装フェーズの分割案

各フェーズは**単独でデプロイ可能**（前フェーズの状態でも壊れない）ように切っています。

### Phase 0 — 非破壊の下地づくり（DB 変更なし）

- `data-msg-id` / `data-log-id` の付与
- `DetailPanel` に `initialTab` prop 追加（未指定時は現行と同じ挙動）
- 既存の未読集計クエリに `id` / `created_at` を追加（表示は変えない）
- `buildNotificationFeed()` を定義するが **UI には未接続**
- `notifFlash` keyframes の追加

**成果**：見た目の変化ゼロ。デグレリスク最小。単独でコミット可。

### Phase 1 — DB migration

- `add_order_change_logs_read_by.sql` を作成 → **実行前にユーザー確認**
- ロールの格納場所（`auth.users.raw_app_meta_data` か `profiles` か）を先に確認（§2-4 注記）
- `messages.read_by` の GIN インデックス有無を確認、無ければ追加
- backfill（§2-4 ③、案A で確定）
- RPC `mark_message_read` / `mark_change_log_read` を作成
- 動作確認：Supabase 上で `read_by` が正しく追記されるか手動検証

**成果**：DB のみ変更。アプリは Phase 0 のまま動く。

### Phase 2 — 管理者ベル + パネル（表示のみ）

- サイドバーに 🔔 追加、`adjCount+soudCount` バッジを 📋 直下へ移動 + `title` 付与
- `fetchNotifications()` をフィード生成に統合（クエリ本数を**増やさない**、§7-1）
- 通知パネル（ドロワー）を実装、フィルタチップ・空状態込み
- 一覧カードのバッジをフィード由来に差し替え
- **クリックしても遷移しない**（この時点では表示確認のみ）

**成果**：ベルが立つ。既存機能は無変更。ここで実データを見て件数・文言を調整。

### Phase 3 — 管理者のクリック遷移 + 個別既読

- `openNotification()` / `markOneRead()` / `scrollTarget` の実装
- **`bottomRef` 自動スクロールの抑止（§4-4）← 最初に実装する**
- リトライ + タイムアウト
- ハイライト演出
- 「すべて既読」ボタン

**成果**：管理者側が完成。ゴール1〜4を満たす。

### Phase 4 — 顧客側

- トップバーに 🔔、右下 E-Li 吹き出しをベルへの導線に転換
- ボトムシート型パネル（既存ピッカーの構造を再利用）
- `ChatScreen` 側のスクロールターゲット受け
  （画面遷移が別 screen なので、`App` レベルで `scrollTarget` を保持し `ChatScreen` に prop で渡す）
- `mention` / `chat` のみ。`change` は該当なし（§0 の前提）

**成果**：ゴール5を満たす。

### Phase 5 — 整理・拡張（任意）

- `markChatRead()` の案件一括既読とベル個別既読の整合レビュー（決定：一括は**維持**）
- 旧 RPC `mark_messages_read(p_order_id, p_email)` の削除
- `site_history` / `status_logs` / `schedule_history` をフィードに追加
  （`type` を増やすだけで済む設計になっている）
- `order_change_logs` と `site_history` の**二重書き込み**の整理
  （`index.html:4400-4420`, `4488-4506` でほぼ同じ内容を2テーブルに入れている。
  　片方は自動既読・片方はボタン既読という非対称がある）

---

## 7. パフォーマンス影響と対策

### 7-1. クエリ本数を増やさない（むしろ減らす）

現状の 3秒ポーリング：

| 画面 | 現状 | 統合後 |
|---|---|---|
| 管理者 | **4本**（messages×2, site_history, order_change_logs）`index.html:10004-10054` | **3本**（messages×1, site_history, order_change_logs） |
| 顧客 | **2本**（orders, messages）`index.html:5767-5793` | **2本**（据え置き） |

管理者の `messages` への2クエリ（`from_role='user'` 用と `from_role='staff'` 用）は、
`from_role` の絞り込みを外して **1本にまとめ、JS 側で type 判定**できます。
`read_by`・`sender_id` 条件は共通なので、これは純粋な削減です。

### 7-2. 二段構え：ポーリングは軽量列のみ

**ポーリング（3秒ごと）** — バッジ件数の算出に必要な最小列だけ：

```
messages          : id, order_id, from_role, sender_id, mentions, created_at
order_change_logs : id, order_id, changed_by, changed_at
```

`text` / `field_name` / `old_value` / `new_value` は**取らない**。

**パネルを開いた時（1回だけ）** — 表示用の列を `in('id', ids)` で追加取得しキャッシュ：

```
messages          : id, text, sender_name
order_change_logs : id, field_name, old_value, new_value
```

これにより、**閉じている間はチャット本文を一切ネットワークに乗せない**。
3秒×常時のトラフィックが本文長に比例して膨らむのを防ぎます。

### 7-3. 厳守事項

- **`select('*')` は使わない。**
  現行コードも通知系では使っていない（`index.html:10012`, `10025`, `10048`）ので、この規律を維持
  - 例外：`index.html:7444` の変更履歴取得は `select('*')`。Phase 2 で必要列に絞る
- **`.limit(100)` + `.order('created_at', desc)` を必ず付ける。**
  現状リミットなしは案件数に対して線形に悪化する
- **インデックス前提**：`read_by` の GIN、`changed_at` の btree（§2-4）。
  無いと 3秒ごとに seq scan が走る
- **パネルは閉じている間 mount しない。**
  `{showNotifPanel && <NotificationPanel .../>}` とし、非表示時のツリーをゼロにする
- **ベルバッジは `useMemo` で件数だけ算出。**
  フィード配列が毎回新規生成されるため、`AdOrderCard` 群が全再描画されないよう
  `order_id → count` のオブジェクトを浅い比較が効く形で作る
  （現行 `unreadCounts` と同じ形状を維持すれば既存の描画コストは変わらない）
- **個別既読は 1リクエスト。**
  現行 `markChatRead()` は N 件を `Promise.all` で並列 UPDATE（`index.html:10467-10471`）＝ N リクエスト。
  ベル経由の個別既読は RPC 1本で済むため、**むしろ軽くなります**

### 7-4. 計測（デプロイ前に必ず実施）

| 指標 | 測り方 | 許容 |
|---|---|---|
| `fetchNotifications()` 平均レスポンス | Network タブ、20回平均 | 変更前比 +0% 以下（本数を減らすため） |
| ポーリング1回の転送量 | Network の Size 合計 | 変更前より減っていること |
| ベルクリック → パネル描画 | Performance タブ | 200ms 以内 |
| 通知クリック → スクロール完了 | 目視 + console.time | 1秒以内 |
| 一覧スクロール時の FPS | Performance タブ | 変更前と同等（フレーム落ちなし） |

---

## 8. 決定事項（ユーザー承認済み）

| # | 論点 | 決定 |
|---|---|---|
| 1 | 移行時の過去ログ扱い | **案A：全既読化**（移行日以前の行に全 admin/manager を `read_by` に投入） |
| 2 | チャット未読もベルに載せるか | **メンション＋チャット両方**（フィルタチップで切替可能に） |
| 3 | 案件一括既読を残すか | **維持**（チャットタブを開くと案件全体が既読。個別既読と矛盾しない） |
| 4 | `adjCount+soudCount` バッジ | **📋 直下へ移動 + `title` 付与**（ベルには統合しない） |
| 5 | `read_by` の型 | **`text[]`**（`messages.read_by` と統一） |

---

## 9. 想定リスク

| リスク | 影響 | 緩和 |
|---|---|---|
| `bottomRef` 自動スクロールとの競合 | 該当メッセージへ飛んだ直後に最下部へ戻る | §4-4 の抑止を Phase 3 の**最初**に実装。動作確認の必須項目 |
| 削除済みメッセージを指す通知 | クリックしても何も起きない | リトライ上限（§4-2 ④）＋ 見つからなければトースト「該当メッセージは削除されました」＋ 既読化 |
| `read_by` の lost update | 既読が消えて再度未読化 | RPC 化（§2-5）で原子的に追記 |
| 移行後の大量未読 | 初日にベルが3桁 | §2-6 案A（決定済み） |
| 単一 HTML の肥大化 | 現在 558KB / 10,760行。Babel standalone のコンパイル時間が伸びる | 新規追加は概算 +300〜400行。パネルは1コンポーネントに集約し、管理者/顧客で共有する |
| 顧客側の `change` 通知が空 | ベルが常に「メンションとチャットだけ」 | §0 の前提として明示済み。Phase 5 で `status_logs` を追加すれば埋まる |

---

## 10. 変更対象ファイル一覧

| ファイル | 変更 | Phase |
|---|---|---|
| `index.html` | ベル・パネル・遷移・下準備すべて | 0, 2, 3, 4 |
| `add_order_change_logs_read_by.sql`（新規） | `read_by` 追加・index・backfill | 1 |
| `add_notification_rpcs.sql`（新規） | `mark_message_read` / `mark_change_log_read` | 1 |
| `CLAUDE.md` | 通知フィードの規約を追記 | 5 |
| `docs/notification-bell-plan.md`（本書） | — | — |

---

## 付録：調査で判明した既存実装の参照表

| 対象 | 行 |
|---|---|
| 🗑️ 下のバッジ（実体は `adjCount+soudCount`） | `10549-10555` / 算出 `10479-10480` |
| 管理者 通知集計 `fetchNotifications()` | `10004-10054` |
| 管理者 3秒ポーリング | `10093-10098` |
| 管理者 案件一括既読 `markChatRead()` | `10452-10472` |
| 管理者 カードバッジ描画 | `7163-7190` |
| 管理者 タブ state / タブボタン | `7340` / `7752-7756` |
| 管理者 チャット遅延ロード | `10101-10108` |
| 管理者 メッセージバブル | `8661-8694` |
| 管理者 最下部スクロール | `7342`, `7370` |
| 管理者 変更履歴 取得 / UI / 確認 | `7440-7446` / `8409-8444` / `7477-7488` |
| 顧客 未読集計（初回 / ポーリング） | `5744-5761` / `5767-5793` |
| 顧客 カードバッジ描画 | `3715-3728` |
| 顧客 E-Li 吹き出し | `6083-6096` |
| 顧客 メッセージバブル | `5498-5520` 付近 |
| 顧客 最下部スクロール | `5196`, `5199` |
| 顧客 既読化 | `5242-5259` |
| App ルーター（画面遷移関数） | `10662-10678` |
| `mapChat()` | `6690-6710` |
| `order_change_logs` 書き込み（写真 / テキスト） | `4413-4419` / `4498-4506` |

> ⚠️ 上表の行番号は **Phase 0 適用前**（10,760行時点）のもの。
> Phase 0 で +61行されているため、6,712行目以降は最大 +61 ずれる。
> 現在の行番号は §11 の Phase 0 適用結果を参照。

---

## 11. 進捗記録

### 2026-07-28

#### Phase 0 — 完了・本番デプロイ済み

コミット `e3e5461`（`main`）。`index.html` +71 / -10、10,760 → 10,821行。
挙動変化ゼロ。本番 `eli.markan.co.jp` / `hacchu-kanri-v2.vercel.app` で
ログイン・実描画まで確認済み。

適用後の行番号:

| 内容 | 行 |
|---|---|
| `HI_CSS` の `notifFlash` | 3552 |
| 管理者 `<style>` の `notifFlash` | 10570 |
| 顧客バブル `data-msg-id` | 5521 |
| 管理者バブル `data-msg-id` | 8739 |
| 変更履歴行 `data-log-id` | 8483 |
| `DetailPanel` シグネチャ（`initialTab` / `tabSeq`） | 7356 |
| 同 useEffect | 7448-7455 |
| `AdminApp` の state | 10047-10048 |
| `DetailPanel` 呼び出し | 10667 |
| 管理者 select 列追加 | 10072 / 10084 / 10108 |
| 顧客 select 列追加 | 5747 / 5777 |
| `buildNotificationFeed()` | 6712-6757 |

計画書 §6 との差分: `tabSeq` を Phase 0 時点で追加した。`initialTab` だけだと
同じタブを連続指定したときに useEffect が再発火しないため。

#### Phase 1 — 途中まで完了

**完了したもの**

- `order_change_logs.read_by text[] NOT NULL DEFAULT '{}'` 追加済み
  - 全13行が空（`{}`）。backfill は未実行
  - `confirmed_by` は無傷（設定済み13 / NULL 0）
- `profiles.eli_notification_excluded boolean NOT NULL DEFAULT false` 追加済み
  - `info@markan.co.jp` を `true` に設定済み
  - backfill 対象は 8名 → **7名** で確定

**調査で確定した事実**

| 項目 | 結果 |
|---|---|
| ロールの格納場所 | `auth.users.raw_app_meta_data ->> 'role'` が正（`user_metadata` ではない） |
| admin/manager | 8名。`info@markan.co.jp` は `manager` |
| `profiles` 行が無い admin/manager | **0件** |
| `order_change_logs` | 13件、すべて `confirmed_by` 設定済み・未確認0件 |
| `messages` | **259行**。GIN インデックスは不要と判断 |
| `messages.read_by` | メール文字列の残骸 **0件**（クリーン） |
| `is_system` の UUID | `7893dda8-bee1-4e6f-8cd4-3514ef5db2e4` = `info@markan.co.jp` = 「インフォ さん」の三重一致を確認 |

**§2-4 からの設計変更（実データを見て判断を変えた点）**

1. **インデックスは作らない。** `order_change_logs` 13行・`messages` 259行では
   プランナが Seq Scan を選ぶため、GIN は使われず INSERT コストだけが増える。
   1,000行を超えた時点で `CREATE INDEX CONCURRENTLY` で追加する（DDL は
   `add_order_change_logs_read_by.sql` STEP 3 にコメントで用意済み）。
2. **backfill の条件を `changed_at < now()` から `confirmed_by IS NOT NULL` に変更。**
   調査から実行までの間に顧客が現場情報を変更した場合、その新規行まで
   既読化して見逃すため。未確認の行は自動的に対象外になり未読で残る。
3. **通知除外は `is_system` 流用ではなく `eli_notification_excluded` 新設（案B）。**
   `profiles` は3システム共有で、各システムは接頭辞付き列を使う規約
   （`seed_note_excluded` / `mk_connect_role`）。`is_system` は唯一の
   無接頭辞列であり、E-Li 固有の意味を載せると他システムから
   意図せず書き換えられる経路ができる。また `is_system=true` は
   メンション候補からの除外（`add_mention_candidates_rpc.sql:105,124`）を
   伴うため、将来「人間だが通知不要」なアカウントに流用すると副作用が出る。
   両者は併存させる。

#### 次回の再開地点（→ 2026-07-29 に実施済み）

`add_order_change_logs_read_by.sql` の STEP 2（backfill）から再開する予定だった。
実施結果は次節「2026-07-29」を参照。

---

### 2026-07-29

#### Phase 1 — 完了

**① backfill（`add_order_change_logs_read_by.sql` STEP 2）**

273-288行のコメントを外して UPDATE のみを実行。`UPDATE 13`。

STEP 4 の確認 SELECT 結果:

| 確認項目 | 結果 |
|---|---|
| `read_by` が空の行 | **0**（13件すべてに投入） |
| `read_by` 要素数の最小〜最大 | **8 〜 8**（管理者7名 + `changed_by` 1名） |
| `confirmed_by` 不変チェック | 設定済み13 / NULL 0（backfill 前と同一） |
| メール文字列の混入 | 0 |
| UUID 形式でない要素 | 0 |
| `messages` 行数 | 269 → GIN インデックスは不要と再確認 |

要素数が一律8だったのは、13件すべてで `confirmed_by` が
通知対象7名のいずれかと重複し、`changed_by`（顧客）1名だけが
上乗せされたため。7/28 の予想「8〜10」の下限に収まっており想定内。

**② RPC 2本（`add_notification_rpcs.sql` 新規）**

`mark_message_read(bigint)` / `mark_change_log_read(uuid)` を作成。
どちらも `RETURNS void` / `LANGUAGE plpgsql` / `SET search_path = public, auth, pg_temp`。

#### §2-5 からの設計変更（3点・ユーザー承認済み）

**1. `mark_message_read` は SECURITY INVOKER にした（DEFINER ではない）**

§2-5 では2本とも DEFINER で書いていたが、実際の RLS を確認して変更した。

- `messages` の UPDATE ポリシー `messages_update`
  （`fix_rls_policies_comprehensive.sql:158-175`）は
  「自分の注文 OR `get_my_role()` が admin/manager/staff」を許可している
- 顧客側 `fetchOrders` は `.eq('user_id', user.id)`（`index.html:5732`）で
  自分の注文しか取らない
- → **通知に出る＝クリックし得る全員が、既に UPDATE 権を持っている**

権限を広げる必要が無いのに DEFINER にすると RLS が丸ごとバイパスされ、
認可を関数内に書き直す責任が発生する。書き直した認可がポリシーとズレた
瞬間に穴になる。INVOKER のままなら認可は RLS ポリシー1箇所に残り、
ポリシーを直せば RPC も自動的に追随する。

**RPC にする本質的な理由は権限ではなく原子性。**
`array_append` を1文の UPDATE にすれば、READ COMMITTED の行ロックにより
lost update は原理的に発生しない（後続 UPDATE は先行トランザクションの
コミットを待って WHERE を再評価し、更新後の `read_by` を読み直す）。
これは DEFINER / INVOKER と無関係に得られる。

**2. `mark_change_log_read` は DEFINER 必須のまま**

`order_change_logs` の UPDATE ポリシーは admin/manager 限定
（`add_order_change_logs.sql:35-38`）で staff が既読を打てない。
ポリシーを staff に広げると `confirmed_by` / `confirmed_at` まで
書き換え可能になり、§2-2 で分離した意味が崩れる。
→ ポリシーは広げず、`read_by` だけを触る DEFINER の RPC 1本を穴として開ける。
認可は関数内に明示（述語は `get_mention_candidates` の
`authorized` CTE と同形）。

> ⚠️ **【2026-07-31 追記】この判断の前提「staff もベルを使う」は、
> 現行コードでは成立していない。**
> `staff` は `AdminApp` に到達できない。関門が3つあり、いずれも
> `admin` / `manager` だけを通す:
>
> | # | 箇所 | staff の行き先 |
> |---|---|---|
> | 1 | `index.html:10957` `handleLogin` | 顧客画面（履歴） |
> | 2 | `index.html:10943-10947` `onAuthStateChange` | 顧客画面（履歴） |
> | 3 | `index.html:10345` `AdminApp` init | `onLogout()` で強制退出 |
>
> ロールの参照元は3箇所とも `app_metadata.role`。
> CLAUDE.md は「`user_metadata.role` で管理」と書いており食い違っている
> （既知の「ロール二重管理の食い違い」の一部）。
>
> **RPC 側は変更しない。** DEFINER は安全側の選択であり、
> `read_by` しか触らないため `confirmed_by` の保護は保たれている。
> ロールゲートを staff に開放したときに前提が復活する設計として、
> そのまま残す。ここは「根拠が現状に合っていない」ことの記録であって、
> 修正の指示ではない。

**3. 自分除外は `messages` 側のみ**

`mark_message_read` には `sender_id IS DISTINCT FROM auth.uid()` を入れた。
`read_by` は「既読 N」表示の根拠でもあり（`index.html:6959-6960`）、
自分を入れると送信者が自分のメッセージの既読数に数えられる。
既存 `markChatRead` も `sender_id.neq.${uid}`（`index.html:10523`）で
同じ除外をしている。

`mark_change_log_read` には入れない。こちらは「既読 N」表示が無く
`read_by` は純粋に未読判定専用で、かつ backfill で `changed_by` を
投入済み（自分の変更は自分にとって既読）のため、
自己除外を入れると backfill と規約が食い違う。

#### 実行時に判明した問題：`REVOKE ... FROM public` では anon を剥がせない

RPC 作成後の確認で、**両関数とも `anon` に EXECUTE が残っていた。**

原因は Supabase プロジェクトの初期設定に含まれるデフォルト権限:

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
```

これにより `public` スキーマに関数を作った瞬間、`anon` に**明示的な**
EXECUTE 権が付与される。一方 `REVOKE ALL ON FUNCTION ... FROM public` が
剥がすのは PUBLIC 疑似ロール経由の**暗黙の**権限だけで、
`anon` への直接の GRANT には届かない。
REVOKE が効かなかったのではなく、別のものを剥がしていた。

**対処**（`add_notification_rpcs.sql` STEP 3）:

```sql
REVOKE ALL ON FUNCTION public.mark_message_read(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_message_read(bigint) TO authenticated;
```

`PUBLIC` も残すのは、将来この既定設定が変わって暗黙付与に戻った場合に
効かせるため。どちらの経路で付いているかに依存しない書き方にした。
`service_role` / `postgres` は意図的に残す（§12 のメール通知バッチから
呼ぶ可能性があるため）。

**加えて STEP 3.5 に `has_function_privilege()` によるアサーションを新設。**
「成功したように見えて権限が残る」が実際に起きたため、目視確認だけに
頼らず機械的に止める。`has_function_privilege()` は PUBLIC 経由・
ロール継承経由も含めた実効権限を返すため、経路によらず判定できる。

再実行後、`anon` = 両関数とも権限なし / `authenticated`・`service_role` = あり
を確認。

> **プロジェクト全体の作法として**: `public` スキーマに RPC を追加するときは
> 必ず `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon;` を書く。
> CLAUDE.md への追記は Phase 5。
> 根治として `ALTER DEFAULT PRIVILEGES` 自体を変える手もあるが、
> Supabase の標準設定を書き換えると PostgREST のスキーマキャッシュ等に
> 影響が及ぶ可能性があるため、関数ごとの明示 REVOKE を方針とする。

#### 既存 RPC の権限診断（STEP 4 ④）

同じ原因が過去の RPC にも効いているはずなので診断した。

| 関数 | SECURITY | anon 実行 | 評価 |
|---|---|---|---|
| `mark_messages_read(text,text)` | — | — | **DROP 済み**でリスト外。解消済み |
| `get_mention_candidates(text)` | DEFINER | 可 | 調査 →「低」で確定 → **剥奪済み** |
| `get_my_role()` | INVOKER | 可 | 実害なし。**剥奪済み** |

`mark_messages_read` が消えていたことで、`read_by` への UUID 以外の
混入経路（email 追記）は塞がっている。§2-5 の「Phase 5 で削除候補」は
対応済みとして扱う。

#### `get_mention_candidates` の調査と対処（`check_get_mention_candidates.sql`）

**結論: 危険度「低」。情報漏洩は成立していなかった。多層防御として anon を剥奪した。**

調査対象は3点。

**① 何を返す関数か（個人情報の範囲）**

`RETURNS TABLE (id uuid, name text, kind text, company_name text)`
＝ **氏名と会社名**を返す。`profiles` には `phone` 列があるが参照していない。
メール・電話・住所は返さない。ただし `kind='staff'` 側は案件に紐づかず
**社内スタッフ全員**を返す設計のため、破られれば社内名簿が丸ごと出る。

**② anon で本当に 0 行か**

| 検証 | 方法 | 結果 |
|---|---|---|
| DB 内シミュレーション B-1 | `SET LOCAL ROLE anon` + claims あり | 0 行 |
| DB 内シミュレーション B-2 | 同上 + claims なし | 0 行 |
| **本番 HTTP 実測（STEP E）** | publishable key で `POST /rest/v1/rpc/...` | **`[]`（空配列）** |
| 疎通確認 | 同経路で `get_my_role` | `null` が返り経路は生きていた |
| **剥奪後の再実測** | 同経路で `get_my_role` | `null` → **`{"code":"42501"}`** |

最後の行が対処の効果を示している。剥奪前は `null` を返していた
`get_my_role` が、剥奪後は本番 HTTP 経路で
`permission denied for function get_my_role` に変わった。
＝ `REVOKE` が PostgREST の経路まで確かに効いている。

`get_mention_candidates` 自体は剥奪後に直接叩いていないが、
同一ファイル・同一形式の `REVOKE` を同時に適用し、
`fix_rpc_anon_grants.sql` STEP 3 のアサーションと STEP 4 の
`has_function_privilege()` で両関数とも anon = 権限なしを確認済み。

DB 内シミュレーションだけでは PostgREST のロール切替・JWT 検証を
通らないため、本番 HTTP 実測を決定的な証拠とした。
疎通確認を先に行い、`[]` が「認可が効いた 0 行」であって
「鍵や URL の誤りによる失敗」ではないことを担保している。

**③ `authorized` CTE は anon を弾く設計か**

**結果的に閉じているが、明示されていない。**

本プロジェクトの公開鍵は `sb_publishable_...` 形式（`index.html:311`）で
旧来の JWT 形式 anon キーではないが、いずれにせよ未ログインでは
`app_metadata` と `sub` が存在しない。よって

- `get_my_role()` → NULL（`auth.jwt() -> 'app_metadata'` が NULL）
- `auth.uid()` → NULL

となり、`CASE` のどの `WHEN` にも該当せず `ELSE false` に落ちる。
`auth.uid() IS NULL` の明示チェックは存在しない。
**今は閉じているが、`CASE` に条件が1つ足された時や `get_my_role()` の
実装が変わった時に静かに開く構造**であり、SECURITY DEFINER で氏名を
返す関数をその状態で anon に開けたままにする理由が無い。

**対処（`fix_rpc_anon_grants.sql`）**

`get_mention_candidates(text)` と `get_my_role()` から
`REVOKE ALL ... FROM PUBLIC, anon` を実施。`authenticated` は
`GRANT EXECUTE` で維持（メンション候補ピッカーが使う：
`index.html:5220 / 6822 / 7431`）。`service_role` / `postgres` は
サーバー側の信頼済みロールなので触らない。

**`get_my_role()` の剥奪には副作用の可能性があった。**
この関数は RLS ポリシーの内側から呼ばれており
（`fix_rls_policies_comprehensive.sql` の `orders` / `schedules` /
`messages` / `sites` ほか）、ポリシー式は呼び出し元の権限で評価される。
anon から剥奪すると該当テーブルへの anon クエリが「0 行」ではなく
`permission denied for function get_my_role` で落ちる。

未ログインで発行されるテーブルクエリは **`index.html:1071`
（新規登録の企業ID照合）の1箇所だけ**で、対象の `companies` の
SELECT ポリシー（`add_company_is_active.sql:14-21`）は
`auth.jwt()` を直接参照し `get_my_role()` を経由しない。
これを見込みで済ませず、`fix_rpc_anon_grants.sql` STEP 1 に
**トランザクション内で REVOKE → anon で登録フローのクエリ実行 → ROLLBACK**
のドライランを入れて実証してから本番適用した。

剥奪後の性質変化として、将来 anon から `orders` 等を引く実装が入ると
「0 行」ではなく「エラー」になる。fail-closed であり望ましい方向だが
認識しておくこと。

#### 【未対応・別途調査】anon 実行可能な public 関数の棚卸し

`fix_rpc_anon_grants.sql` STEP 0 ② の全件列挙で、今回対処した2本の他にも
anon から実行可能な関数が残っていることが判明した。
今回のスコープ外のため**対処していない**。次回の作業項目とする。

大半はトリガー関数や他システム由来で、引数から値を生成するだけ／
DB のデータを読まないため無害と判断した。
一部に呼び出し元の特定が必要なものがある。

> ⚠️ **本リポジトリは public。個別の関数名と評価はここに書かない。**
> 対象の一覧と所見は Notion「Claude Memory」に記録している。
> 未監査の関数名を公開リポジトリに列挙すると、`anon` からは
> 本来列挙できない情報を与えることになるため。
> 今日 `get_mention_candidates` を「修正してから公開する」順序に
> したのと同じ理由。

> ⚠️ この Supabase プロジェクトは E-Li / MK Daily / Seed Note の
> 3システムで `auth.users` / `profiles` を共有している。
> 残っている関数には E-Li のものではないものが含まれるため、
> 権限を変更すると**他システムを壊しうる**。
> どのシステムのどの画面が呼んでいるかを特定してから触ること。
> E-Li 側の判断だけで剥奪しない。

判断基準は「DB のデータを読む関数かどうか」。
`gen_random_uuid` のような純粋関数は対象外。

#### 次回の再開地点

> ⚠️ **ベル作業の前に §13「次回優先タスク」を実施する。**
> ロゴ・キャラ画像の最適化は低リスクかつ効果が大きく、先に片付ける。
> 7/28 時点の判断のまま据え置き。

**Phase 1 は完了。次回は Phase 2（管理者ベル + パネル・表示のみ）から。**

`index.html` への変更は Phase 0 以来の再開になる。§6 Phase 2 を参照。
Phase 2 の要点:

- サイドバーに 🔔 追加、`adjCount+soudCount` バッジを 📋 直下へ移動 + `title` 付与
- `fetchNotifications()` をフィード生成に統合（クエリ本数を増やさない、§7-1）
- 通知パネル（ドロワー）を実装、フィルタチップ・空状態込み
- 一覧カードのバッジをフィード由来に差し替え
- **この時点ではクリックしても遷移しない**（表示確認のみ）

Phase 0 で `buildNotificationFeed()`（`index.html:6712-6757`）を
定義済みだが UI 未接続なので、そこから繋ぐ。

**積み残し（ベル本体とは独立）**:

1. 上記「anon 実行可能な public 関数の棚卸し」の調査
   （対象一覧は Notion「Claude Memory」を参照。呼び出し元の特定が先）
2. §13-1 ロゴ・キャラ画像の最適化（配信 12.9 MB → 数十 KB）
   → **2026-07-30 実施済み**（108.6 KB。§11「2026-07-30」参照）
3. §13-2 Supabase Usage の確認
   → **2026-07-30 に最適化前値を取得**（Egress 3.12 GB / 62.4%）。
     最適化後の再測定は数日後

#### Phase 1 で追加・実行した SQL ファイル（コミット対象）

| ファイル | 内容 | 実行状況 |
|---|---|---|
| `check_role_storage.sql` | ロール格納場所の調査（読み取り専用） | 実行済み |
| `check_is_system.sql` | `is_system` と `info@` の調査（読み取り専用） | 実行済み |
| `add_profiles_eli_notification_excluded.sql` | 通知除外列の追加 | 実行済み |
| `add_order_change_logs_read_by.sql` | `read_by` 追加・backfill・確認 | **STEP 0/1/1.5/2/4 実行済み**（STEP 3 インデックスは意図的に未実行） |
| `add_notification_rpcs.sql` | RPC 2本・権限・確認 | **全 STEP 実行済み** |
| `check_get_mention_candidates.sql` | 既存 RPC の露出調査（読み取り専用） | 実行済み（STEP A〜E） |
| `fix_rpc_anon_grants.sql` | 既存 RPC 2本の anon 剥奪 | **全 STEP 実行済み** |

**Phase 1 は DB のみの変更。`index.html` は Phase 0 のまま無変更で動く。**

#### この日の作法上の学び（CLAUDE.md へ Phase 5 で反映）

`public` スキーマに RPC を追加するときは必ず
`REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon;` を書く。
`FROM public` だけでは Supabase の `ALTER DEFAULT PRIVILEGES` による
anon への明示付与が残る。加えて `has_function_privilege()` による
アサーションを併記し、目視確認に頼らない。

---

### 2026-07-30

#### §13-1 画像最適化 — 完了

**配信 12.79 MB → 108.6 KB（99.17% 減）。** 目視確認済み・PNG 11枚削除済み。

| ファイル | 元 | 変換後 | 削減 |
|---|---|---|---|
| `eli_img.webp` | 1024×1536 / 2262.7 KB | 400×600 / 43.9 KB | 98.06% |
| `logo_img.webp` | 1536×1024 / 2042.5 KB | 480×320 / 13.1 KB | 99.36% |
| `ariri_yojo.webp` | 1024×1536 / 2532.3 KB | 133×200 / 11.4 KB | 99.55% |
| `ariri_barashi.webp` | 1024×1536 / 2599.4 KB | 133×200 / 12.7 KB | 99.51% |
| `ariri_hakobii.webp` | 1024×1536 / 1908.8 KB | 133×200 / 13.5 KB | 99.30% |
| `ariri_pikaai.webp` | 1024×1536 / 1745.8 KB | 133×200 / 14.2 KB | 99.19% |

リサイズ目標は「最大表示サイズ × 2（Retina）」。alpha は6枚とも保持（4ch）。

#### §13-1 の記述で誤っていた点（2点・実測で判明）

**1. 対象は `index.html` だけではなかった。**
静的3ページも同じ PNG を参照しており、`index.html` だけ直して PNG を
削除すると `/privacy-policy`・`/security`・ご利用ガイドの画像が壊れる。

| ファイル | 行 | 参照 |
|---|---|---|
| `eli-guide.html` | 555, 961 | `logo_img` |
| `eli-guide.html` | 561, 875 | `eli_img` |
| `privacy-policy.html` | 218, 393 | `logo_img` |
| `security-guide.html` | 266, 455 | `logo_img` |

差し替えは「7行」ではなく **4ファイル・15行**だった。

**2. `markan_logo.png` は「✅ 参照」ではなく未参照だった。**
`index.html:317` で定数 `MARKAN_IMG` を定義しているだけで描画箇所ゼロ。
定数ごと削除した。未参照ファイルは4枚ではなく **5枚**。

#### 変換手段の変更：`sips + cwebp` → `sharp`（npm）

計画時は sips + cwebp を想定していたが、このマシンでは**両方使えない**。

- `cwebp` 未インストール、Homebrew も未インストール
- `sips` は WebP を**書けない**（`Error: Can't write format: org.webmproject.webp`）

`node v20.20.2` / `npm 10.8.2` は利用可能なため、`sharp` でリサイズと
WebP 化を1パスで実施した。sips も cwebp も不要。
作業ディレクトリはリポジトリ外（スクラッチパッド）に置き、
`node_modules` の誤コミットを防いだ。

#### 品質設定の判断

ariri 4枚は `index.html:2300` の1箇所で `mixBlendMode:"multiply"` により
カード背景（`#e8f4ff` 等）へ乗算合成される。alpha 付き画像を lossy WebP に
すると、エッジのにじみが色付き輪郭として乗算で目立つ恐れがあるため、
**ariri のみ q=90**（他は q=85）、全体で `alphaQuality=100` とした。
目視確認の結果、にじみは発生せず。

#### 表示サイズの根拠（今後の再変換時に参照）

| 画像 | 最大表示 | 根拠 |
|---|---|---|
| `eli_img` | h300 | `.login-libot` 300px / eli-guide `.hero-libot` 300px |
| `logo_img` | h160 | `.login-logo-img` 160px / eli-guide `.logo-img` 160px |
| `ariri_*` | h100 | `index.html:2300` のみ（レスポンシブ変化なし） |

#### 削除した PNG 11枚（22.2 MB）

差し替え済み6枚 + 未参照5枚（`markan_logo.png` / `eli_img.png.PNG` /
`logo_img.png.PNG` / `ariri_shiwake.png.PNG` / `ariri_kidzuki.png.PNG`）。

**リポジトリサイズは縮まない。** git 履歴に blob が残るため `git clone` の
サイズは不変。`git filter-repo` は実施しない方針。縮むのは配信量のみで、
それが本命の効果。§13-1 の「リポジトリサイズの縮小」は誤り。

> なお `indexのコピー.html`（5/20 のローカル退避・4,319行）が削除した PNG を
> 参照しているが、`.gitignore` 済みでデプロイされないため放置してよい。

#### Egress 実測

| 時点 | Egress | 使用率 |
|---|---|---|
| 2026-07-24 | 2.55 GB | 51.0% |
| **2026-07-30（最適化前）** | **3.12 GB** | **62.4%** |
| 最適化後 | 次回測定 | — |

6日で +0.57 GB（約 95 MB/日）のペース。今回の最適化がここに効くはずなので、
**数日後に再測定して傾きの変化を見る**こと。効果が出ていなければ
Egress の主要因は画像ではない（DB クエリ側）ということになる。

#### 次回の再開地点

**Phase 2（管理者ベル + パネル・表示のみ）から。** §6 Phase 2 を参照。
`buildNotificationFeed()`（`index.html:6712-6757`）は Phase 0 で定義済み・
UI 未接続なので、そこから繋ぐ。

積み残し:

1. anon 実行可能な public 関数の棚卸し（残12関数。対象一覧は Notion
   「Claude Memory」。呼び出し元の特定が先。3システム共有のため
   E-Li 判断だけで剥奪しない）
2. §13-2 Egress 再測定（上記のとおり数日後）

---

### 2026-07-31

#### Phase 2 完了 ＋ Phase 3 の主要部完了・本番デプロイ済み

コミット `dbd7ebc`（`index.html` 1ファイル・+305 / -44）を `main` に push。
本番 https://hacchu-kanri-v2.vercel.app が同内容であることを byte 一致で確認済み
（574,761 bytes / `diff` なし）。

**Phase 2（管理者ベル＋パネル）**

- サイドバー 📋 直下に 🔔 を追加。未読数バッジ付き（100件超は `99+`）
- `adjCount+soudCount` バッジを 🗑️ 直下から 📋 直後へ移動し
  `title="要対応（調整中・相談中）"` を付与（§3-1 のとおり）
- 通知パネル `AdNotifPanel` を新設（ドロワー・`left:60 / width:360 / z-index:150`）。
  ヘッダー（未読 N ／すべて既読／×）、フィルタチップ4種、空状態 📭、
  相対時刻 `notifAgo()`、本文抜粋（60字）
- 🔔 / 🏢 / 👷 は同時に開かない
- `fetchNotifications()` を `buildNotificationFeed()` に接続。
  一覧カードのバッジもフィードから導出し、ベルとカードを同期（§3-4）
- ポーリングのクエリ **4本 → 3本**（§7-1 のとおり `messages` を1本に統合）
- 本文はパネルを開いた時だけ `in('id', ids)` で取得（§7-2 二段構え）

**Phase 3 のうち実装した範囲**

- `openNotification(n)` を単一エントリポイントとして実装（§4-1）。
  順序は **①案件を開く → ②タブを決める → ③既読**（ユーザー指定）。
  既存の受注一覧カードの経路（`OrderList` の `onSelect` ＝ `setSelected`,
  `index.html:7508` / `10885`）にそのまま合流させた。
  カードは order オブジェクトを渡すので、通知の `orderId` から
  `ordersRef.current` で実体を引き当ててから渡している
- タブ指定は Phase 0 で用意済みの `detailInitialTab` / `detailTabSeq` を利用
  （`DetailPanel` 側の受けは `index.html:7616-7620`）。
  `change` → `detail` タブ、`chat` / `mention` → `chat` タブ
- 個別既読は Phase 1 の RPC（`mark_message_read` / `mark_change_log_read`）。
  「すべて既読」は確認ダイアログ付き

**Phase 3 で未実装**：欄内スクロール（`scrollTarget`・§4-4 の `bottomRef`
自動最下部スクロールの抑止・ハイライト演出）。ユーザー判断で次段階へ送った。

#### 実装中に判明した事実・設計判断

**1. `from_role='eli'` の除外は必須だった**

§7-1 の「`from_role` の絞り込みを外して1本にまとめる」をそのまま実行すると、
LiBot の自動メッセージが全管理者に通知として飛ぶ。
LiBot は `sender_id` を持たないまま insert されるため
（`index.html:4553` / `10477` ほか）、`sender_id.is.null` の条件に全件が
引っかかる。`.in('from_role', ['user','staff'])` を入れて
統合前の2クエリの範囲と一致させた。§7-1 の記述は
「`from_role` の絞り込みを外す」ではなく
「**`user` と `staff` の2値に絞ったうえで1本にする**」が正しい。

**2. `order_change_logs` の未読判定を `confirmed_by` → `read_by` に切替**

`index.html:10106` の一覧カード用クエリは `confirmed_by IS NULL` のままだった。
`read_by` に切り替えると意味が「誰も確認していない」から「自分が読んでいない」に
変わるが、これは §2-2 の意味分離のとおり。
ただし切り替えるとバッジを消す唯一の経路だった
「✅ 確認済みにする」で消えなくなるため、`handleConfirmChanges`
（`index.html:7541`）でも `mark_change_log_read` を打つようにした。

**3. `.limit(100)` による頭打ち（既知の上限）**

§7-3 の「リミット必須」に従って両クエリに `.limit(100)` を付けた。
バッジ件数はフィードから導出しているため、
**未読が各テーブル100件を超えるとバッジも100で頭打ちになる。**
現状の実データでは到達しないが、仕様として記録しておく。

**4. `ordersRef` が必要だった（stale closure）**

`fetchNotifications()` は `useEffect([])` から3秒ポーリングされるため、
`orders` を state から読むと初回レンダーの空配列に固定される。
`buildNotificationFeed()` は `orders` に無い `order_id` を捨てる仕様なので、
ref を経由しないとフィードが常に空になる。
`useEffect(() => { ordersRef.current = orders }, [orders])` で同期している。

**5. チャットタブの案件一括既読との相互作用**

チャットタブが開くと既存の effect（`index.html:7622-7625`）が
`onMarkChatRead(order.id)` を呼び、その案件の未読メッセージが全件既読になる。
したがって**チャット通知を1件クリックすると同案件の他のチャット通知もまとめて消える**。
§5（Phase 5）の「一括は維持」という決定どおりなので、そのままとした。
変更ログ側にはこの一括処理が無く、クリックした1件だけが消える。

**6. staff は `AdminApp` に到達できない**

§2-5「2. `mark_change_log_read` は DEFINER 必須のまま」に追記したとおり。
このため「staff に消せないバッジが残る」という
デプロイ前の懸念は発生しないことを確認したうえでデプロイした。

#### 未実施・積み残し

1. Phase 3 の残り（欄内スクロール・`bottomRef` 抑止・ハイライト演出）
2. Phase 4（顧客側のベル）
3. anon 実行可能な public 関数の棚卸し（残12関数。対象一覧は Notion
   「Claude Memory」。呼び出し元の特定が先。3システム共有のため
   E-Li 判断だけで剥奪しない）
4. §13-2 Egress 再測定
5. `add_user_companies.sql` は untracked のまま据え置き（今回もスコープ外）
6. `add_notification_rpcs.sql` 冒頭17行目の「★ このファイルはまだ実行しないこと」は
   実行前に書かれたまま残っている。実際は全 STEP 実行済み（§11 の表 `add_notification_rpcs.sql` 参照）

#### 次回の再開地点

**Phase 3 の残り（欄内スクロール）から。** §4-2 / §4-3 / §4-4 を参照。
§4-4 の `bottomRef` 自動最下部スクロールの抑止を**最初に**実装すること。

---

### 2026-08-01

#### メール通知 A案（即時送信）— 「日程確定」1イベントを実装・本番稼働

§12 の先行実施。ベルの Phase 3 残りより先に着手した（顧客への到達手段が
先に要るという判断）。**`index.html` は1行も変更していない。**

##### 構成

```
管理者が status を 日程確定 に変更（A/B/C いずれの経路でも）
  └→ orders AFTER UPDATE OF status トリガー
       WHEN (status が変化 AND 新値='日程確定' AND deleted_at IS NULL)
       └→ net.http_post（pg_net・非同期）
            body: { event:'schedule_fixed', order_id }   ← これだけ
            header: x-eli-notify-secret（Vault から取得）
            └→ Edge Function send-order-notification（Verify JWT OFF）
                 ① 共有シークレット照合（定数時間比較）
                 ② orders を id で引く（存在／未削除／user_id有／status再確認）
                 ③ profiles.eli_notification_excluded 確認
                 ④ auth.admin.getUserById(order.user_id) で宛先解決
                 ⑤ Resend 送信 → eli_email_log に記録
```

##### 作成物

| ファイル | 内容 |
|---|---|
| `edge-function-send-order-notification.ts` | Edge Function のソース控え（実体は Supabase 側） |
| `add_email_notification_schedule_fixed.sql` | pg_net / ログテーブル / Vault / トリガー関数 / トリガー / 検証 / 切り戻し |

DBオブジェクト: `public.eli_email_log`、`public.eli_notify_schedule_fixed()`、
`trg_eli_notify_schedule_fixed`（on `public.orders`）。
Vault シークレット: `eli_notify_secret` / `eli_notify_url`。
Edge Function Secrets 追加: `ELI_NOTIFY_SECRET` / `APP_URL`
（既存の `RESEND_API_KEY` / `SERVICE_ROLE_KEY` / `FROM_EMAIL` は流用）。

##### 動作確認

`net.http_post` の直接テストで `status_code = 200` / `{"success":true}` を確認。
テストアカウント「てすと えとう」`mikanq1031@gmail.com` に**実際に着信**し、
メールのデザインも確認済み。テスト案件は B-2026-403「ちゃんとメール届くかな」。

##### `send-reset-email` から意図的に変えた点

1. CORS を付けない。POST 以外は 405（サーバ間専用のため）
2. 共有シークレットで認証する（`send-reset-email` は無認証。誰でも叩ける）
3. **宛先をリクエストボディで受け取らない。** `order_id` だけ受け取り、
   `orders` → `auth.users` とサーバ側で解決する。
   これが「他システムのユーザーに混入させない」ための唯一の担保
4. `await` されない（pg_net が非同期にキューへ積む）。§12-1 の要件

##### 設計上の決定

- **本文に案件情報を一切載せない。**確定した日付すら書いていない（§12 の方針を厳密適用）。
  件名は「【E-Li】作業日程が確定しました」＋リンクのみ
- **`eli_email_log` に宛先メールアドレス本体を保存しない**（`@` 以降のドメインのみ）。
  ログが顧客メールアドレスの二次的な保管場所になるのを避ける
- トリガー関数は `EXCEPTION WHEN OTHERS THEN RETURN NEW` で囲う。
  メール通知の異常が「日程確定」という業務操作を巻き込んで失敗させない（§12-2）
- 自動完了ループ（`index.html:10443`）は status を `完了` にするだけなので
  このトリガーは発火しない。**全管理者のブラウザが60秒ごとに実行する箇所なので、
  ここに送信処理を足していたら端末数だけ重複送信になっていた**

##### 他システムへの影響（調査済み・ゼロ）

`orders` / `schedules` / `status_logs` / `order_change_logs` / `messages` /
`schedule_history` / `site_history` / `companies` を参照している他システムは
hoyojo-app・mk-daily・mk-connect・seed-note・hoyojo-guide の**いずれにも無い**。
共有しているのは `profiles` のみで、本機能は `eli_notification_excluded` を**読むだけ**。

他4システムに `functions/v1` 呼び出しも `supabase/functions` ディレクトリも
Resend 利用も**ゼロ**（`seed-note/docs/disaster-recovery.md:396` に明記）。
`send-reset-email` と本関数がこの Supabase プロジェクト唯一の Edge Function。

新規オブジェクトの命名は `add_profiles_eli_notification_excluded.sql:14` の
「各システムは自分の接頭辞付き列を使う」規約に従い `eli_` を付けた。

##### ★ ハマりポイントと教訓（3点）

**① シークレットは必ず1つの値を Vault と Edge Function の両方に貼る。**
別々に生成すると `401 unauthorized` になる。今回はこれで長時間を費やした。
生成は `SECRET=$(openssl rand -hex 32); echo "$SECRET"; printf '%s' "$SECRET" | pbcopy`
の1回だけにし、その値を2箇所に貼る。`printf '%s'` で末尾改行を除くのが要点。

**② `vault.update_secret` に値を貼るときは64桁だけを入れる。**
角括弧・空白・改行を混ぜない。検証は
`length(decrypted_secret)=64` と `decrypted_secret ~ '^[0-9a-f]{64}$'` の両方で見る。

**③ トリガー関数の `EXCEPTION WHEN OTHERS` は例外を握り潰すため、
`net._http_response` が0行になり「トリガーが発火していない」ように見える。**
これは設計どおりの挙動（業務操作を止めないため）だが、切り分けを著しく困難にする。
**`net.http_post` を SQL から直接叩いてトリガーをバイパスする**のが最も速い切り分け。
Vault からシークレットをインラインで読ませれば画面に実値も出ない。

```sql
SELECT net.http_post(
  url     := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='eli_notify_url'),
  body    := jsonb_build_object('event','schedule_fixed','order_id','<受付番号>'),
  headers := jsonb_build_object('Content-Type','application/json',
             'x-eli-notify-secret',
             (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='eli_notify_secret')),
  timeout_milliseconds := 5000) AS request_id;
```

切り分け表: `0行`＝トリガー未発火または例外握り潰し ／ `401`＝シークレット不一致 ／
`404`＝関数名・URL誤り ／ `200 {"skipped":...}`＝ガードで停止（`content` に理由） ／
`500`＝Resend 側 ／ `200 {"success":true}`＝送信成功。

##### 別件バグ発見（未対応・別タスク）

**`cases` の RLS がアプリと別の場所を見ている。**

- アプリは会社を「`user_companies.is_primary` → `profiles.company_id`」の
  優先順で解決する（`index.html:3276-3290`）
- しかし `cases` の RLS は `profiles.company_id` しか見ない
  （`add_cases_table.sql:96` / `fix_cases_rls_insert.sql:11-17`）
- → `user_companies` に紐付けがあり `profiles.company_id` が NULL のユーザーは、
  アプリ上は発注に進めるのに `cases` の INSERT で RLS 違反になる
  （三値論理で `company_id = NULL` → NULL → WITH CHECK 不成立）

今回は `saimura0314` の `profiles.company_id` に `MK-A3X9` を埋めて回避した（対症療法）。
**根本対応（RLS を `user_companies` も見るように直す）は別タスク。**

あわせて `add_cases_table.sql:79-94` の admin/manager・staff ポリシーは
`auth.jwt() -> 'user_metadata' ->> 'role'` を参照しているが、コードとその他のSQLは
一貫して `app_metadata.role`（既知の「ロール二重管理の食い違い」の一部）。
`cases` の管理者ポリシーが実際には機能していない可能性がある。未検証。

##### 次回の優先順

1. **【最優先】チャット送信の通知。** スタッフがチャットを送ったら、
   **2時間後に未読なら**顧客へメール。今回作った配線をそのまま流用する。
   §12「懸念：Resend の送信数無料枠」の「未読のときだけ送信」を最初から採る形。
   判定に必要な `read_by` は Phase 1 で揃っている
2. **キャリアメール（`@docomo.ne.jp` 等）への到達。**
   Resend のドメイン認証（SPF/DKIM）が未完了なのが原因。
   `markan.co.jp` の DNS 設定が要る（ネームサーバーはさくらインターネット
   `ns1.dns.ne.jp` / `ns2.dns.ne.jp`）。**実顧客はキャリアメールが多いため重要**
3. キャンセル・変更イベントのメール追加（今回は日程確定のみ）。
   `EVENTS` にキーを足し、トリガーを1イベントにつき1つ追加する
4. テスト案件 B-2026-403「ちゃんとメール届くかな」のクリーンアップ
5. （従前からの積み残し）ベル Phase 3 の残り＝欄内スクロール、Phase 4、
   anon 実行可能な public 関数の棚卸し（残12関数）、§13-2 Egress 再測定

---

## 12. 将来拡張：メール通知（ベル完成後）

> **2026-08-01 追記：本節は一部実装済み。**
> 「日程確定」1イベントのみ A案（即時送信）で本番稼働している。
> 実装の詳細・構成図・教訓は §11「2026-08-01」を参照。
> 設計方針として当初「`buildNotificationFeed` の上に乗せる」（クライアント側集約）と
> 書いていたが、**採用したのは DBトリガー＋pg_net＋Edge Function（サーバ側集約）**。
> 理由は ①クライアントを1行も重くしない ②status 変更の3経路を1箇所でカバーでき
> 書き漏れが起きない ③多端末による重複送信が原理的に起きない、の3点。
> 以下の要件・懸念は未実装分（チャット・キャンセル・変更）にそのまま有効。

### 目的

E-Li 上でアクションが発生したときに、顧客へメールで気づいてもらう。
ベルはログインしていないと見えないため、ログイン導線としてのメールが要る。

### ★最優先要件：画面を絶対に重くしない

メール通知は**付加機能であり、アプリ本体の体感速度より優先されることは無い**。
以下を設計の前提条件とする。機能を削ってでもこれを守る。

1. **送信は必ず非同期（裏側）で実行する。**
   画面描画・チャット送信の応答を待たせない。
   チャット送信ボタンを押してからメッセージが表示されるまでの間に、
   メール送信の完了を待つ実装にしない（`await` しない、
   または Edge Function をキューとして呼び捨てる）。

2. **送信失敗をアプリ本体に波及させない。**
   Resend が落ちていても、レート制限に当たっても、
   チャット送信そのものは成功させる。
   失敗はログに残すだけで、UI にエラーを出して操作を止めない。

3. **定期チェック（2時間後に未読なら送信、など）は絞り込みクエリで軽量に保つ。**
   全件走査や全案件ループを組まない。
   `read_by` に受信者が入っていない かつ 一定時間経過、という
   条件で DB 側に絞らせ、必要列のみ取得する（§7-3 の規律をそのまま適用）。
   ポーリング間隔は通知ベルの3秒とは分離し、分〜時間単位にする。

この3点は §7（パフォーマンス影響と対策）の延長線上にある。
ベル本体で `select('*')` 禁止・`limit` 必須・パネル非表示時は mount しない、
という規律を敷いたのと同じ理由で、メール通知でも徹底する。

### 仕様の骨子

| 項目 | 内容 |
|---|---|
| トリガー | チャット送信 / 日程確定 / キャンセル / 変更 |
| 宛先 | 主に顧客 |
| 本文 | 「新着あり」＋ リンクのみ。**メッセージ本文は載せない** |
| タイミング | 都度送信 |
| 基盤 | 既存の Resend Edge Function を流用 |

**本文を載せない理由**: メールは転送・誤送信・端末での閲覧が制御できないため、
案件情報や会話内容をメール本文に含めない。リンク先で認証を通してから見せる。

**基盤について**: パスワードリセットで Resend の実績がある
（`edge-function-send-reset-email.ts`）。新規にメール基盤を立てる必要はない。

### 設計方針

**通知ベルのイベント検知（`buildNotificationFeed`）の上に乗せる。**

ベルとメールで「何が通知対象か」の判定を1箇所に集約する。
別々に条件を書くと、片方だけ通知される・両方来ないといった不整合が必ず起きる。

日程確定・キャンセルはベルのフィードに `type` を追加して拡張する。
`NotificationItem`（§1-1）は最初から `type` 拡張可能な形にしてあるので、
`'schedule_fixed'` / `'cancelled'` などを足せばフィードとメールの両方に載る。

これは §0 の非ゴールに挙げた「`status_logs` / `schedule_history` のフィード統合」
（Phase 5）と同じ作業になるため、まとめて実施するのが効率的。

### 懸念：Resend の送信数無料枠

案件規模は月 350〜400 訪問。1訪問あたり数通なら当面は無料枠内に収まる想定だが、
チャットの往復が多い案件では都度送信が積み上がる。

**超えそうな場合の対策**: 「未読のときだけ送信」に切り替える。
`read_by` に受信者が入っていない状態が一定時間続いた場合のみ送る、
という判定にすれば送信数を大幅に減らせる。この判定に必要なデータは
Phase 1 で入れた `read_by` にすべて揃っている。

**着手前にやること**: Resend の現在の送信数と無料枠の上限を実測で確認する。
§13-2 の Supabase Usage 確認と同じタイミングでまとめて見るのが効率的。

### 次回確認すること

**顧客のメールアドレスが DB に登録されているか。**

宛先が取れなければメール通知は成立しないため、着手判断より前に確認が要る。
確認対象:

- 案件（`orders`）側に顧客のメールアドレスを持つ列があるか
- お客様マスタ（`profiles` / `companies` / `user_companies`）側にあるか
- `auth.users.email` を使うのか（＝ログインアカウントのメール＝通知先でよいのか）

`auth.users.email` はログイン用アドレスであり、現場担当者への連絡先とは
別物である可能性がある（`orders` には `site_contact_name` /
`site_contact_phone` があるが、メール列があるかは未確認）。
「誰に送るか」が確定しないと §12 の設計は進められない。

---

### 12-A. 残りの通知施策（2026-08-03 確定・未実装）

3件ある。**うち1件はメールではなくチャット投稿**なので混同しないこと。
文面の全文は別途受領予定（未受領）。実装順は未定。

#### ① 顧客向けメールの拡充（当社 → 顧客 / 既存 `send-order-notification` を拡張）

送信対象は4イベント。

| # | イベント | 起点 | 状態 |
|---|---|---|---|
| 1 | 発注受付 | `orders` INSERT | 未実装 |
| 2 | 日程確定 | `status` → 日程確定 | **実装済み**（2026-08-01） |
| 3 | キャンセル | `status` → キャンセル | 未実装 |
| 4 | 日程相談中 | `status` → 日程相談中（当社都合で別日を相談） | 未実装 |

- **メールを送らないステータス: 調整中・完了。**
- **顧客発のステータス（日程変更相談中・キャンセル相談中）はメール不要。**
  顧客自身の操作なので通知は要らない。当社側は通知ベルで気づく。
- 全メール共通の体裁:
  - 件名の先頭に `【大阪マルカン E-Li】`
  - 冒頭で「株式会社大阪マルカン E-Li（イーライ）総合窓口です」と名乗る
  - リンク先 `eli.markan.co.jp` を明示する
- 実装は2〜4とも同じ型（`EVENTS` にキーを足し、イベントごとにトリガーを1つ追加）。
  1 だけは `AFTER INSERT` になる。
- ⚠️ **「調整中は除外」と「発注受付で送る」は実装時に整理が要る。**
  発注直後の `status` は 調整中 であり、受付メールは INSERT 起点で1回だけ送る、
  という理解で矛盾しないが、`status` 起点のトリガーと二重に発火しないことを確認する。

#### ② チャット未読リマインドメール（当社 → 顧客）

- 当社スタッフがチャットを送信し、**顧客が2時間読まなければ**顧客へメール。
- 判定に必要な `read_by` は Phase 1 で揃っている。
  §12「懸念：Resend の送信数無料枠」の「未読のときだけ送信」を最初から採る形。
- **pg_cron が必要。**

#### ③ 施工日4日前のお知らせ（チャット投稿 ＋ メール の二段構え）

**【2026-08-03 確定】チャット単体ではなく、チャット投稿と同時にメールを1通送る。**
顧客側にベルが無い（Phase 4 未実装）ため、チャットに投稿しただけでは
顧客が気づけない。メールは気づかせる（＝E-Li を開かせる）ためだけに使う。

- **施工日の4日前・朝9時**に実行。**pg_cron が必要。**
- **チャット**（E-Li 名義で自動投稿）: 詳細を書く。
  日程・作業名・確認依頼。施工日・時間・作業名を `orders` から差し込む。
- **メール**（顧客宛・1通）: 誘導のみ。**具体的な日程・作業名は書かない。**
  漏洩防止のため。詳細はチャット側にあり、リンク先で認証を通してから見せる
  （§12「本文を載せない理由」をそのまま適用）。

**メール文面（確定）**

件名:

```
【大阪マルカン E-Li】作業日程が近づいてまいりました
```

本文:

```
○○様

いつもお世話になっております。
株式会社大阪マルカン E-Li（イーライ）総合窓口です。

まもなく作業日程が近づいてまいりますので、
担当者よりメッセージをお送りしております。

ご変更の有無や、現場の詳細情報について、
下のボタンから E-Li にてご確認いただけますと幸いです。

[E-Li を開いて確認する]

※ボタンは当社サイト eli.markan.co.jp へのリンクです。
```

- メール側の差し込みは `○○様`（顧客名）のみ。
- したがって**下の「差し込み変数の注意」はチャット文面にのみ効く。**
  メールに日付・時間・作業名は入らない。

**差し込み変数の注意（チャット文面。実装時に必ず確認する）**

1. **日付はそのまま出さない。**
   `2026-10-17` ではなく「10月17日(金)」のように月日＋曜日へ整形する。
   （指示は「和暦＋曜日」。令和表記まで要るかは文面の全文が来た時点で確定させる）
2. **時間は時間帯で持っている可能性が高い。**
   日程確定チャットが「9時〜12時」形式で出しているため。
   文面の「（お時間○○時予定）」にどう入れるかは、実装時に実データの形式を
   確認してから決める（例：「お時間 9時〜12時 予定」）。
3. **作業名の表記を検討する。**
   作業区分「産廃」「清掃・家具移動」等をそのまま出すか、
   顧客向けの丁寧な表記に直すか。
4. **実装後は必ずテスト案件で1件実行し、日付・時間・作業名が自然に入っているかを
   目視で確認する。** 変数が入ることの確認ではなく、文章として読めるかの確認。

⚠️ **実装上の注意**

- **チャット投稿とメール送信はセットで1回。** どちらか片方だけが飛ぶ状態を作らない。
  ただしメール送信の失敗でチャット投稿を巻き戻さない（§12 の最優先要件2）。
- **E-Li 名義（`from_role='eli'`）の投稿は通知クエリから除外される決まり**
  （§11「2026-07-31」）。この投稿は②のチャット未読リマインドの対象にならない。
  顧客に気づかせる手段はここで送る1通のメールだけなので、
  ②が入っても代わりにはならない。
- 顧客側のベル（Phase 4）が入れば、この投稿もベルに載る。
  そのときメールを止めるかどうかは別途判断する。

---

## 13. 次回優先タスク（ベル作業より先に実施）

通知ベル（Phase 1 STEP 2 backfill 以降）に戻る前に、以下を先に片付ける。
どちらも短時間で終わり、リスクが低く、効果が大きい。

### 13-1. ロゴ・キャラ画像の最適化 ★最優先

> ✅ **2026-07-30 完了**（12.79 MB → 108.6 KB）。実施結果と、
> 以下の記述のうち**誤っていた2点**（静的3ページの参照漏れ・
> `markan_logo.png` は未参照）の訂正は §11「2026-07-30」を参照。
> 以下は着手前の計画としてそのまま残す。

#### 現状（2026-07-28 実測）

リポジトリ内の画像は合計 **22.34 MB**。うち `index.html` が参照して
実際に配信されるのは **約 12.9 MB**。

| ファイル | サイズ | 参照 |
|---|---|---|
| `eli_img.png` | 2.21 MB | ✅ 全画面のマスコット |
| `logo_img.png` | 1.99 MB | ✅ ロゴ |
| `ariri_barashi.png.PNG` | 2.54 MB | ✅ 発注フォーム |
| `ariri_yojo.png.PNG` | 2.47 MB | ✅ 発注フォーム |
| `ariri_hakobii.png.PNG` | 1.86 MB | ✅ 発注フォーム |
| `ariri_pikaai.png.PNG` | 1.70 MB | ✅ 発注フォーム |
| `markan_logo.png` | 0.16 MB | ✅ |
| `eli_img.png.PNG` | 2.21 MB | ❌ 未参照（重複） |
| `logo_img.png.PNG` | 1.99 MB | ❌ 未参照（重複） |
| `ariri_shiwake.png.PNG` | 2.62 MB | ❌ 未参照 |
| `ariri_kidzuki.png.PNG` | 2.58 MB | ❌ 未参照 |

**当初の想定（`eli_img` + `logo_img` の約4MB）より対象が大きい。**
`ariri_*.PNG` 4枚が発注フォームで**まとめて読み込まれる**ことを
ローカルサーバーのアクセスログで確認済み（4枚同時に GET されている）。
合計 8.57 MB がフォーム表示時に一度に飛ぶ。

#### 表示サイズとのギャップ

`index.html` 内の画像表示指定は最大で `height:100`。
実際は `height:34` / `36` / `54` / `80` / `100` などで使われている。

**100px 以下で表示するものに 2MB の原寸画像を配信している**状態。
これが最適化余地の本体。

#### やること

1. 各画像の実際の表示サイズを確定する（Retina 対応で2倍まで見込む → 最大 200px 程度）
2. そのサイズにリサイズ
3. WebP 化（PNG のまま縮小するより大幅に軽い）
4. `index.html` の参照パスを差し替え
5. 未参照の4ファイル（9.4 MB）を削除するか判断する

**目標: 配信 12.9 MB → 数十 KB。**

#### 効果

- 表示速度の向上（特にスマホ・モバイル回線）
- Vercel / Supabase の Egress 削減 → 課金リスクの低下
- リポジトリサイズの縮小

#### リスク評価：低

- **リポジトリ内の静的ファイル差し替えのみ。DB に一切依存しない**
- Supabase の transform ではなくファイル自体を置き換えるため、
  実行時の変換コストもかからない
- 差し戻しは git revert のみで完結
- 通知ベルの作業（`index.html` の JSX 部分）とは競合しない

#### 補足

CLAUDE.md の「今後の追加候補（未実装）」に既に記載がある項目。
そこでは「Egress 削減効果が大きい」とだけ書かれているが、
上記の実測値で優先度を上げる根拠が揃った。

### 13-2. Supabase Usage の確認

#### 目的

Egress / Storage が上限にどれくらい近いかを把握し、課金リスクの実態を確認する。

#### 前回の実測（2026-07-24）

| 項目 | 使用量 | 上限 | 使用率 |
|---|---|---|---|
| Storage | 0.186 GB | 1 GB | 18.6% |
| Egress | 2.55 GB | 5 GB | **51.0%** |

#### やること

Supabase ダッシュボード → Settings → Usage で現在値を確認し、
上表と比較して増加ペースを見る。

**Egress が半分を超えている点に注意。** 13-1 の画像最適化は
ここに直接効く（画像配信が Egress の主要因である可能性が高い）。
最適化の前後で数値を比較すれば効果を定量化できる。

#### 関連

§12 のメール通知で Resend の無料枠を確認する必要があるため、
そちらとまとめて見ると効率がよい。

---

## 14. PWA + Web Push（2026-08-11 着手）

### 14-0. 位置づけ ★これが最重要

**この施策は「機能追加」ではなく「ポーリング撲滅の手段」である。**

全システム共通の絶対原則「Supabase の負担は限りなく減らす」（正本 `~/.claude/CLAUDE.md`）に
照らすと、E-Li の Supabase 負荷はほぼ全部が3秒ポーリングに由来する。
Web Push はこれを置き換えるための手段であって、通知機能そのものが目的ではない。

**Phase 1〜3 だけでは負荷は微増する。負荷が下がるのは Phase 4 に到達したときだけ。**
この点は承認済み（2026-08-11）。

### 14-1. 現状把握（2026-08-11 調査）

#### PWA 資産はゼロ

`manifest.json` / `*.webmanifest` / `sw.js` / `service-worker.js` はいずれも存在しない。
`index.html` に `serviceWorker` / `pushManager` / `Notification` / VAPID の参照は **1件も無い**。
`apple-mobile-web-app-*` / `theme-color` の meta も無い。
192/512 のアイコン素材も無い（既存は webp のみ・`logo_img.webp` は 480×320）。

#### 構成

- `index.html` … **574,761 bytes / 11,081 行**の単一ファイル
- `<script id="jsx-source" type="text/jsx-source">`（306行目）に JSX、11,063行目で `Babel.transform`
- CDN 4本：React 18.2.0（固定）／ReactDOM 18.2.0（固定）／
  **@babel/standalone 7.23.6（固定・約2.7MB）**／`@supabase/supabase-js@2`（**浮動**）

#### ★ポーリングの実態（負荷の主因）

`setInterval` は7箇所。うち**3秒間隔が4本**。

| 場所 | 行 | 間隔 | 1回あたりの Supabase 往復 |
|---|---|---|---|
| 管理者 `fetchNotifications` | 10388 | 3秒 | `getUser` + `site_history` + `messages` + `order_change_logs` = 4 |
| 管理者 選択案件チャット | 10416 | 3秒 | `messages.select('*')` = 1 |
| 顧客 `pollUnread` | 5792 | 3秒 | `getUser` + `orders` + `messages` = 3 |
| 顧客 ChatScreen | 5295 | 3秒 | `messages.select('*')` = 1 |
| 自動完了・tick | 5810 / 7259 / 10473 | 60秒 | 0〜1 |

概算（**未実測・Phase 0 で計測すること**）：管理者タブ1枚で 4,800〜6,000 リクエスト/時、
顧客タブ1枚で 3,600〜4,800/時。管理者7名×8時間だけで約27万リクエスト/日。

**別件の即効改善：`sb.auth.getUser()` は Auth サーバーへの往復が発生する
（`getSession()` はローカル読み）。** ポーリング内で毎回呼んでいるので、
`getSession()` に替えるだけで3秒ごとの往復が2本消える。Push とは独立に効く。

#### 開発環境

- **Deno 未インストール／Supabase CLI 未インストール／`supabase/` ディレクトリ無し**
- → Edge Function は**ダッシュボード運用**（本番ソースのヘッダにも明記あり）
- Node v20.20.2 / npm 10.8.2 は利用可
- 検証で CLI や Deno を新規導入すると環境構築という別のリスクを負うため、
  既存のダッシュボード方式に乗せる方針とした

### 14-2. 承認済みプラン（2026-08-11）

| Phase | 内容 | Supabase 負荷 |
|---|---|---|
| **Phase 0** | 計測（DevTools Network ＋ Usage）。推定値は使わない | 変更なし |
| **Phase 1** | PWA化。manifest / アイコン / **キャッシュしない sw.js** / vercel.json に no-cache ヘッダ | **影響ゼロ** |
| **Phase 2** | Push土台。VAPID を Vault へ／`eli_push_subscriptions`／購読UI | 書き込みのみ |
| **Phase 3** | 送信。既存 `send-order-notification` に相乗り（新トリガーを作らない） | 微増 |
| **Phase 4** | ★本命：3秒ポーリングを停止／緩和 | **桁で減少** |

承認済みの4点：①Phase 4 で負荷が下がる位置づけでよい ②管理者7名から先行
③Phase 1 の SW はキャッシュ完全無しで始める ④Deno での Push 技術検証を最優先

### 14-3. SW の置き方（この構成特有の地雷）

1. **`index.html` を絶対にキャッシュしない。** アプリ全体が index.html 1枚なので、
   precache するとデプロイしても古いアプリが出続ける。単一ファイル構成では
   SW の precache が最大の事故要因。
2. SW は必ずリポジトリ直下 `/sw.js`（scope `/`）。
   `eli-guide.html` / `privacy-policy.html` / `security-guide.html` も配下に入る。
3. **`sw.js` 自体に `Cache-Control: no-cache` が要る。**
   これが無いと SW の更新が届かず、Push ハンドラを直せなくなる。
   `vercel.json` は現状 `rewrites` のみなので `headers` の追加が必要。
4. キャッシュを導入するとしても Phase 1 の後、**バージョン固定された CDN 3本だけ**。
   `supabase-js@2` は浮動なので対象外（固定すると古い版に貼り付く）。
   Babel standalone 2.7MB の再取得が消えるので体感が大きく変わる。
   これは Vercel/CDN の話で **Supabase 負荷はゼロ**。

### 14-4. 購読テーブル設計（Phase 2 で作る・未実装）

```sql
create table public.eli_push_subscriptions (
  endpoint    text        primary key,          -- ★PK を endpoint に
  user_id     uuid        not null references auth.users(id) on delete cascade,
  p256dh      text        not null,
  auth        text        not null,
  ua          text,
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz,
  fail_count  smallint    not null default 0
);
create index on public.eli_push_subscriptions (user_id);
```

負荷を最小にする要点は**テーブル定義より運用側**にある。

1. **PK を `endpoint` にする** → クライアントは SELECT 無しの `upsert` 1本で済む
2. **★クライアントは「変わったときだけ」書く。** `localStorage` に前回の endpoint を持ち、
   一致したら upsert を発行しない。素直に実装すると全ページロードで upsert が飛ぶ。
   **単独で最大の削減点。**
3. **このテーブルをクライアントから読まない。** client=書き込み専用／
   Edge Function(service_role)=読み取り専用。RLS は `eli_email_sent` と同じで
   `authenticated` に SELECT ポリシーを作らない
   → ★**この方針は 2026-08-13 に修正した。`upsert`（`ON CONFLICT DO UPDATE`）は
   SELECT ポリシーを要求するため、作らないと必ず 403 になる。実際に
   「自分の行だけ」の SELECT ポリシーを1本追加した。詳細は §14-11。**
4. **死んだ購読は Edge Function が消す**（404/410 でその場で delete）。
   **pg_cron の掃除ジョブは作らない**（定期実行自体が恒常負荷）
5. **通知の既読テーブルを新設しない。** 既存の `messages.read_by` /
   `order_change_logs.read_by` で足りる
6. **送信トリガーを新設しない。** 既存 `eli_notify_event()` ＋ Edge Function に相乗りし、
   1回の `net.http_post` でメール＋Push を両方さばく。DB 側の追加負荷は実質ゼロ

> 行数は端末込みでも数十行規模。endpoint のハッシュ化や凝った分割は**この規模では過剰**で、
> 複雑さという別の重さを持ち込むだけなので採らない。

### 14-5. ★技術検証の結果（2026-08-11・合格）

**問い：Supabase Edge Functions の Deno で Web Push を送れるか。**

`jose` だけでは半分しか解決しない。①VAPID 認証（ES256 JWT）と
②ペイロード暗号化（RFC 8291 / ECDH P-256 + HKDF + AES-128-GCM）は別問題で、
`jose` は①のみ。`npm:web-push` は①②を両方やる。
**想定していた失敗要因は「Deno の Node 互換層で `crypto.createECDH` が未実装」**
（`web-push` は `http_ece@1.2.0` 経由でこれを使う）。

#### 検証方法

使い捨て Edge Function `push-test` をダッシュボードに作成。
**本番 `send-order-notification` には一切触れていない。**
DB オブジェクトは1つも作らず、購読はコードに直書き（**Supabase の DB 負荷ゼロ**）。
Secrets は `PUSHTEST_` 接頭辞で新設し、既存 Secrets は上書きしていない。

**切り分けの仕掛け（重要）**
- **`npm:web-push` を動的 import にした。** 静的 import が失敗すると関数自体が起動できず
  原因不明の500になる。`await import()` を try/catch で包めば理由を持ち帰れる
- **ペイロード無しの Push は暗号化を通らない**（`sendNotification(sub, null)` は
  `http_ece` を経由しない）。これで①と②を完全に分離できる
- 3モード：`mode=diag`（診断のみ）／`mode=1`（ペイロード無し）／`mode=2`（ペイロード有り）

#### 結果 — すべて合格

| モード | HTTP | Push サービス | 関数内 | 判定 |
|---|---|---|---|---|
| `diag` | 200 | — | 23ms | import OK・`createECDH` **利用可**（65バイト） |
| `mode=1` | 200 | **201 Created** | 276ms | VAPID + 転送 合格 |
| `mode=2` | 200 | **201 Created** | 180ms | **暗号化まで合格** |

- ランタイム：`supabase-edge-runtime-1.74.3 (compatible with Deno v2.1.4)` / V8 11.6.189.12 / TS 5.1.6
- `npm:web-push@3.6.7` の import は **23ms** で成功
- **想定していた最大のリスク（`createECDH` 未実装）は存在しなかった**

#### 結論

**`npm:web-push@3.6.7` は Supabase Edge Functions でそのまま動く。**
`jose` での自前実装は**不要**。プラン全体は変更なしで進められる。

#### レイテンシの実測（Phase 3 の見積もりに使う）

初回 1.58秒（**コールドスタート**）、2回目以降 0.3〜0.7秒。
DB トリガーからは `pg_net` で非同期に投げるので業務操作は待たされないが、
通知の到達遅延としては現れる。

### 14-6. ★未確認事項：ブラウザでの通知表示

**Push の送信は成功（FCM 201）したが、Mac に通知が表示されなかった。**

#### 切り分けで判明していること

**Push を一切使わないローカル通知テスト（`registration.showNotification()` を
直接呼ぶだけ）でも表示されなかった。** したがって
**送信・暗号化・転送の経路は無関係で、原因は macOS / Chrome の表示層に限定される。**
集中モードはオフだった。

#### Phase 1 で確認すること

- macOS システム設定 → 通知 → **Chrome** の通知許可
- Chrome の サイトごとの通知設定
- 本番 HTTPS 環境（`eli.markan.co.jp`）での再確認

**201 は「Push サービスが受け取った」までしか保証しない。**
経路全体が通ったと言えるのは SW がペイロードを復号して表示できたときなので、
**この確認は Phase 1 の完了条件に含めること。**

#### 実装上の注意（今回踏んだもの）

検証用 SW は `mode=1` と `mode=2` の通知に**同じ `tag` を付けていた**ため、
2通目が1通目を置き換える（Web Push の仕様）。
本番の SW では通知ごとに `tag` を分けるか、意図的にまとめる場合は明示すること。

### 14-7. スコープ外（重要）

**この検証は Chrome デスクトップのみの結果で、iOS/Safari が通った証明にはならない。**

- Apple のエンドポイント（`web.push.apple.com`）は別実装
- **iOS の Web Push は iOS 16.4+ かつ「ホーム画面に追加」済みでないと購読すらできない**
- ホーム画面追加には HTTPS 配信が要る → **Phase 1 完了後でないと試せない**
- → **iOS 検証は Phase 1 の後に独立したマイルストーンとして置く**
- 顧客15名の iOS バージョン分布は未調査。顧客側 Push の採用可否はこれ次第

### 14-8. 次回

**Phase 1（PWA化）から。** Supabase には触れない。

1. 192/512 のアイコン生成（`sharp`。このマシンは cwebp / Homebrew 未インストール）
2. `manifest.json` 新設
3. `index.html` の `<head>` に `link rel=manifest` と iOS 用 meta を数行
4. **キャッシュしない `sw.js`** を root に
5. `vercel.json` に `sw.js` の no-cache ヘッダ
6. デプロイ後、**14-6 の通知表示の確認**と、ホーム画面追加の動作確認

### 14-9. ★kill switch — SW を全端末から撤去する手順

**Service Worker は一度登録すると利用者の端末に居座る。**
壊れた SW を配ると全員が壊れた状態に固定されるため、撤去手段を先に用意しておく。

#### 手順

**Step 1.** `sw.js` の中身を**下記に全置換**して deploy する。

```js
/* E-Li Service Worker — KILL SWITCH（撤去版）
   これを deploy すると、次回アクセスした端末から SW が自動的に外れる。 */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.map((key) => caches.delete(key)));
    await self.registration.unregister();
    const clients = await self.clients.matchAll({ type: 'window' });
    clients.forEach((client) => client.navigate(client.url));
  })());
});
```

**Step 2.** 全端末で撤去されたことを確認する（管理者7名分。DevTools → Application → Service Workers が空）。

**Step 3.** その**後で** `index.html` 末尾の SW 登録スクリプト（`navigator.serviceWorker.register('/sw.js')` のブロック）を削除して deploy する。

#### ★順序を間違えないこと

登録スクリプトを先に消すと、**既に登録済みの端末には撤去版 sw.js が届かず、古い SW が残り続ける**。
必ず「撤去版を配る → 撤去を確認 → 登録スクリプトを消す」の順。

#### なぜ効くのか

`vercel.json` で `/sw.js` に `Cache-Control: no-cache` を付けてあるため、
ブラウザは毎回サーバへ再検証しにいき、差し替えた sw.js が確実に届く。
**このヘッダが無いと kill switch 自体が届かず、撤去できなくなる。**
Phase 2/3 で push ハンドラを修正できるのも同じ理由による。

#### 個別端末の応急処置

DevTools → Application → Service Workers → **Unregister**。
その端末1台だけの対処であり、他の端末には影響しない。

### 14-10. Phase 1 実施記録（2026-08-12・実装完了／未デプロイ）

**Supabase には一切触れていない。**DB・RPC・RLS・Edge Function・Secrets・Vault すべて無変更。
`index.html` の Supabase 呼び出しと `setInterval` 7本も1行も変更していない（Phase 4 の担当）。

#### 追加したファイル

| ファイル | 内容 |
|---|---|
| `manifest.json` | `start_url` `/` ／ `scope` `/` ／ `display: standalone` ／ `theme_color: #2952c8` ／ `background_color: #ffffff` |
| `sw.js` | キャッシュ無し。`install`=skipWaiting ／ `activate`=全キャッシュ削除＋claim ／ `fetch`=空ハンドラ |
| `icon-192.png` | 192×192 / 4.1 KB |
| `icon-512.png` | 512×512 / 15.3 KB |
| `icon-maskable-512.png` | 512×512 / 14.2 KB（セーフゾーン検証済み） |
| `apple-touch-icon.png` | 180×180 / 3.8 KB |

アイコン合計 37.3 KB。Vercel 配信のみで **Supabase 負荷はゼロ**。

#### 変更したファイル

- `index.html` … `<head>` に8行（manifest / theme-color / icon / apple 系 meta）、
  `</body>` 直前に SW 登録スクリプト。**追加のみで既存行の変更は0**
- `vercel.json` … `headers` を追加（`/sw.js` = `no-cache`、`/manifest.json` = `max-age=300`）。
  既存 `rewrites` は無変更

#### アイコン生成の実際（次に差し替えるとき用）

`logo_img.webp` は 480×320 で**周囲が透明**。生ピクセルを走査してロゴ本体の外接矩形を実測すると
**`(63,97)` から `333×110`（縦横比 3.03）**。ここだけを `extract` して白い正方形キャンバスに合成する。

- `purpose: any` は canvas 幅の **74%**、`maskable` は **70%**（中央80%の円に収める必要があるため）
- PNG は **256色パレット＋ディザリング**。フルカラー 50.1 KB → 15.3 KB でグラデーションの劣化は視認できない
- **アルファ無しで出力する**（iOS はアイコンの透過を嫌う）
- `sharp` はこのマシンに未インストール。scratchpad に `npm i sharp` して使い、リポジトリには入れない

#### 設計判断（迷ったら読む）

- **`orientation` を manifest に入れない。** `portrait` にすると管理者画面
  （サイドバー＋一覧＋詳細パネルの横並び）がタブレット横向きで使えなくなる
- **`Content-Type: application/manifest+json` の上書きをしない。** Vercel 既定の
  `application/json` を Chrome / Safari は受け付ける。ヘッダ上書きという余計なリスクを取らない
- **`Service-Worker-Allowed` ヘッダは不要。** `sw.js` がルート直下なので scope `/` は既定で取れる
- **`no-store` ではなく `no-cache`。** 毎回再検証させる方が SW 更新の仕様に合う
- `fetch` ハンドラは**空にする**。`respondWith` を呼ばないので全リクエストは素通りし、
  Supabase への通信を傍受も再送もしない。置いてあるのは、インストール可能判定が
  fetch ハンドラの存在を要求する場合への保険
- `window.open(url,'_blank')` 4箇所はすべて Supabase の署名付きURL（別オリジン・scope 外）なので
  standalone でもブラウザで開く。現行と同じ挙動で問題ない

### 14-11. Phase 2 実施記録（2026-08-13・実装完了／未デプロイ）

**Supabase に初めて触れた回。** DB は本番反映済み、`index.html` は未デプロイ。

#### やったこと

1. **前回の検証用ゴミの撤去**（`push-test` 関数・`PUSHTEST_` Secrets 4件）。
   ダッシュボードで削除済みを確認。既存の `send-order-notification` /
   `send-reset-email` と既存 Secrets は無傷
2. **VAPID 本番鍵の生成**。8/11 の検証用鍵は破棄し、流用しない
3. **`eli_push_subscriptions` を本番に作成**（`add_eli_push_subscriptions.sql`）
4. **購読 UI を `index.html` に追加**（追加のみ +148行 / −0行）

#### VAPID 鍵の扱い

- **依存パッケージ無しで生成した。** Node 標準 `crypto` の
  `generateKeyPairSync('ec', {namedCurve:'prime256v1'})` で `web-push` の
  `generateVAPIDKeys()` と同形式（P-256 / base64url）が出る。
  公開鍵＝非圧縮点65バイト（先頭 `0x04`）→ 87文字、秘密鍵＝32バイト → 43文字
- 生成スクリプトは **8つの健全性チェック**を通してから書き出す。
  とくに**秘密鍵から公開鍵を導出し直して一致するか**と
  **JWK の `x‖y` から再構成して一致するか**の2つは、
  エンコードの取り違えをその場で検出できるので必ず入れる
- **公開鍵は `index.html` に直書きする。** 仕様上おおやけにする値
  （購読時にブラウザ経由で Push サービスへ渡る）なので public リポジトリで問題ない
- **秘密鍵は scratchpad に 0600 で置き、端末にも会話にも表示しない。**
  Secrets への投入は `pbcopy` 経由。★サンドボックス内では `pbcopy` が
  **無言で失敗する**ので、最初からサンドボックスを外して実行し、
  `pbpaste | shasum -a 1` で照合してから貼る
- Supabase Secrets に3件登録：`ELI_VAPID_PUBLIC_KEY` /
  `ELI_VAPID_PRIVATE_KEY` / `ELI_VAPID_SUBJECT`。
  **Phase 2 では誰も参照しない。** 読むのは Phase 3 の Edge Function
- 秘密鍵はパスワードアプリへ退避済み。**紛失すると全端末の購読が無効になり、
  鍵の再生成と全員の購読やり直しになる**

#### テーブル（§14-4 からの変更点は1つだけ）

`add_eli_push_subscriptions.sql` を STEP A / B / C に分けて個別実行。
発行された文は13個で、**すべて `eli_push_subscriptions` を対象**。既存オブジェクトへの変更は0。

**★列名を `auth` ではなく `auth_key` にした。** これが §14-4 からの唯一の逸脱。
PostgreSQL は `x.y()` を「スキーマ `x` の関数 `y`」とも解釈しうるため、
`auth` という列があると RLS 内の `auth.uid()` の解決が壊れる可能性がある。
回避コストは1単語、外した場合のコストは本番のポリシー不正動作なので避ける側に倒した。
（結果として C-4 で `auth.uid()` が正しく効いていることを確認済み）

権限まわりの判断：

- **`SELECT` は権限だけ付与し、ポリシーは作らない。**
  `INSERT ... ON CONFLICT DO UPDATE` は更新式で読む列に SELECT **権限**を要求するため、
  外すと upsert が `42501` で落ちうる。ただし SELECT **ポリシー**が0本なので
  実際に読める行は常に0行。§14-4 の「クライアントから読まない」は RLS 側で担保する。
  **権限と RLS の二段構えで、片方だけ見て判断しないこと**
- **`DELETE` は権限もポリシーも与えない。** 利用者が通知を止めるときは
  `unsubscribe()` で endpoint が無効になり、次の送信で Edge Function が 410 を受けて消す。
  行を消すためだけに攻撃面を広げない
- **UPDATE ポリシーを `USING (true)` にした。** 共用 PC でアカウントが替わると
  endpoint は同じまま `user_id` だけ変わる。`USING (user_id = auth.uid())` だと
  その端末では以後ずっと購読できず、しかも原因が分かりにくい。
  endpoint は当該端末からしか取得できない秘匿値なので引き継ぎを許す側に倒す。
  `WITH CHECK (user_id = auth.uid())` で「他人名義の行は作れない」は維持
- **`ON DELETE CASCADE` で掃除ジョブを不要にした。** 退職者のアカウント削除で
  購読行も消える。pg_cron を持ち込まずに後始末が済む
- `last_ok_at` は**送信成功のたびに書かない**旨を COMMENT に明記した。
  書くと「通知1件 × 端末数」の UPDATE が恒常的に発生して絶対原則に反する

#### 検証（STEP C・7項目すべて合格）

| | 内容 | 結果 |
|---|---|---|
| C-1 | RLS 有効 | `relrowsecurity = true` / `relforcerowsecurity = false` |
| C-2 | **anon の4権限** | **すべて false**（最重要） |
| C-3 | authenticated の権限 | SELECT / INSERT / UPDATE = true、**DELETE = false** |
| C-4 | ポリシー | **2本のみ**（INSERT / UPDATE）。SELECT / DELETE / ALL は無し |
| C-5 | トリガー | **0本** |
| C-6 | インデックス | PK(endpoint) と user_id の**2本のみ** |
| C-7 | 列構成 | 8列。**`auth` という列が無い** |

★**新規テーブルは既定権限で anon に4権限が自動で付く。** RLS を有効にしただけでは
足りず `REVOKE ALL ... FROM PUBLIC, anon, authenticated` が要る。
STEP A と B の間は、押したボタンによってはテーブルが開いた状態になる。
**A を流したら B は続けて流すこと。**

★Supabase の SQL Editor は複数文をまとめると最後の SELECT しか表示しない。
STEP C の7つは1つずつ流す。各ブロックは `pbcopy` + sha1 照合で渡した。

#### `index.html`（追加のみ +148行 / −0行）

ハンクは2つだけ。既存行の変更・削除は0。

- `AD_NOTIF_META` の直後 … 定数2つ・ヘルパー4つ・`ensurePushSubscription()`・`PushOptIn`
- `AdNotifPanel` のヘッダー直下 … `<PushOptIn />` の1行

**`AdNotifPanel` 本体に手を入れず独立コンポーネントにした。**
既存の通知パネルのロジックは1文字も変わっていない。

負荷設計（§14-4 の実装）：

- `serviceWorker.ready` / `getSubscription()` / `Notification.permission` は**すべてローカル**。
  ネットワークに出ない
- **`localStorage['eli_push_endpoint']` と一致したらその場で return し、upsert を出さない。**
  単独で最大の削減点
- ★**保存する値は endpoint 単体ではなく `"<user_id>|<endpoint>"`。**
  共用 PC でアカウントが替わると endpoint は同じまま `user_id` だけ変わるので、
  endpoint だけで比較すると**行が前の利用者のまま残り、新しい利用者に通知が届かない**。
  この形なら切り替わった1回だけ upsert が流れる（UPDATE を `USING (true)` にした理由と対）
- **`getUser()` ではなく `getSession()`。** 前者は Auth サーバーへ往復する
- **`.select()` を呼ばない。** supabase-js v2 は `Prefer: return=minimal` になり応答本文も作らない
- `setInterval` 7本は無変更。`sb.` 参照は 185 → 187（`getSession` と `upsert` の2つだけ）
- **定常状態での Supabase へのリクエスト増加はゼロ。** 生涯で端末あたり数回の upsert のみ

UI は `Notification.permission` の3値＋iOS 非 standalone＋エラーの5表示。
**`requestPermission()` はクリックハンドラ内でのみ呼ぶ**（ページ読み込み時に勝手に出さない）。

#### ★JSX 構文チェックの方法（今後も使う）

アプリ全体が `index.html` 1枚なので、**構文エラー＝全画面停止**。デプロイ前に必ず通す。

scratchpad に `npm i @babel/standalone` して、`jsx-source` ブロックを抜き出し
**アプリ本体と同じ設定**（`index.html:11220` の `Babel.transform(src, {presets:['react']})`）
でコンパイルできることを確認する。528,225 bytes / 10,902行が通ることを確認済み。
`sharp` と同じくリポジトリには入れない。

#### ★本番で起きた不具合と対処（2026-08-13・解決済み）

**デプロイ後、本番 Chrome で購読を許可すると upsert が 403 で落ちた。**

```
new row violates row-level security policy for table "eli_push_subscriptions"
```

**原因：`upsert` は `INSERT ... ON CONFLICT DO UPDATE` を発行する。
`ON CONFLICT DO UPDATE` が付くと、競合行を扱うために PostgreSQL は
SELECT ポリシーも適用する。素の INSERT では評価されない経路。**

このテーブルは §14-4 の「クライアントから読ませない」を
**SELECT ポリシーを1本も作らない**ことで実現していた。適用可能な SELECT ポリシーが
存在しない＝全拒否なので、行の内容や `auth.uid()` の値と無関係に upsert は必ず落ちる。
**テーブルが0行でも落ちる**（競合行の有無ではなく、ポリシーの不在が理由）。

★**設計時の見落とし**：`ON CONFLICT` が要求するのは SELECT **権限**だけだと考え、
権限は付与し（C-3 で `a_select = true` を確認）ポリシーは作らなかった。
**権限とポリシーは別物で、両方要る。**

##### 切り分けの経過（推測で潰さず、実測で1つずつ消した）

最初に疑ったのは「認証コンテキストの欠落」だったが、**すべて反証された**。
遠回りに見えるが、この順で消したから原因が一意に定まった。

| 疑い | 検証 | 結果 |
|---|---|---|
| クライアントが送る `user_id` が違う | DevTools の Payload を確認 | 本人の UUID で正しい |
| Authorization が載っていない | DevTools の Request Headers | 載っている |
| ロールが `anon` になっている | エラーコード | **反証。** `anon` なら INSERT 権限が無いので `42501 permission denied` になる。実際は RLS violation ＝権限は通っている |
| `auth.uid()` がプロジェクト全体で壊れている | 案件に写真を1枚追加 | **反証。** `order_change_logs` への INSERT（`with check (changed_by = auth.uid())`）が成功し、変更通知まで生成された |

★**`get_my_role()` を「`auth.uid()` の疎通確認」に使ったのは誤りだった。**
この関数の実装は `auth.jwt() -> 'app_metadata' ->> 'role'`（`fix_rls_policies_comprehensive.sql:58`）で、
**`auth.uid()` を一切参照しない**。切り分けに使う関数は、必ず定義を読んでから選ぶこと。

★**最終的に効いたのは「動いている隣のテーブルとの差分比較」。**
`order_change_logs`（成功）と `eli_push_subscriptions`（失敗）を並べると、
構造的な違いは2点しか残らなかった。

| | `order_change_logs` | `eli_push_subscriptions` |
|---|---|---|
| 発行される文 | 素の INSERT | **INSERT ... ON CONFLICT DO UPDATE** |
| WITH CHECK 式 | `changed_by = auth.uid()` | `user_id = auth.uid()`（同型） |
| 値の入れ方 | クライアントが明示送信 | クライアントが明示送信（同じ） |
| **SELECT ポリシー** | **あり** | **無し** ← ★ |

##### 対処（`fix_push_select_policy.sql`）

```sql
CREATE POLICY eli_push_sub_select ON public.eli_push_subscriptions
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());
```

**ポリシー1本を足しただけ。`index.html` は変更していない**（`user_id` は明示送信のまま、
コミット `4c70113` と同一）。権限・列・インデックス・既存2本のポリシーも無変更。

読めるのは `user_id = auth.uid()` の行だけ、つまり**自分の端末の購読だけ**で、
その中身（endpoint と鍵）は**その端末のブラウザが既に持っている値**。
他人の購読は読めない。anon は権限ごと剥奪済みで全遮断のまま。

★**§14-4 の「このテーブルをクライアントから読まない」の担保方法が変わった。**

- これまで … ポリシーが無いから読めない（DB が強制）
- これから … **クライアントに読むコードを書かない**（規約で守る）

実装は `.select()` を1度も呼んでおらず、`ensurePushSubscription()` が出すのは
upsert 1本だけ。**負荷は不変。**

##### 不採用にした案

- **`ALTER COLUMN user_id SET DEFAULT auth.uid()`** … `auth.uid()` が正常だと判明した時点で
  この不具合とは無関係。原因は WITH CHECK ではなく SELECT ポリシーの不在なので、
  既定値を付けても同じく落ちる。作りかけた `fix_push_user_id_default.sql` は削除した
- **`upsert` をやめて「INSERT して 23505 なら UPDATE」** … クライアントのコードが増え、
  衝突時に往復が2回になる。ポリシー1本で済む話に見合わない

##### 結果

`fix_push_select_policy.sql` 実行後、本番で購読が成功。
**`eli_push_subscriptions` は 1行**（`rows=1` / `with_user=1` / `latest=2026-08-13 14:29:47`）、
UI も「✅ この端末で通知を受け取ります」に変わった。**Phase 2 完了。**

##### 教訓（次にテーブルを作るとき）

- **`upsert` を使うテーブルには SELECT ポリシーが要る。** 「クライアントに読ませない」を
  ポリシーの不在で表現すると upsert が壊れる。読ませたくないなら
  **自分の行だけの SELECT ポリシー**を置き、読まないことはクライアント側の規約で守る
- **権限（GRANT）とポリシー（RLS）は別の壁。** 片方だけ見て「閉じている/開いている」を判断しない
- **切り分けに使う関数は定義を読んでから選ぶ**（`get_my_role()` の件）
- **動いている隣の実装との差分比較が最短。** 同じ `auth.uid()` を使うのに
  一方が通り一方が落ちるなら、違いは有限個しかない

#### 未確認・次回

- ★**購読は本番 Chrome で確認済み（2026-08-13）。iPhone は未確認。**
  ホーム画面の E-Li からの購読は未実施。
  §14-6 の「通知が表示されない」問題も未解決のまま
- **把握している穴**：`navigator.serviceWorker.ready` は SW 登録が失敗している端末では
  解決しない。その場合 `state` は `'checking'` のままで **UI が何も表示されない**
  （エラーは出ないが購読导線も出ない）。実機で問題が出たらタイムアウトを入れる
- **`pushsubscriptionchange` は未対応。** ブラウザが endpoint をローテートすると
  静かに届かなくなる。SW からは Supabase のセッションが使えないので設計判断が要る。Phase 3 で扱う
- Phase 3（送信）… 既存 `eli_notify_event()` ＋ `send-order-notification` に相乗りし、
  1回の `net.http_post` でメール＋Push を両方さばく。DB 側の追加負荷は実質ゼロ。
  **成功時に `last_ok_at` を書かない**こと。404/410 はその場で DELETE
- ★**Supabase 負荷が下がるのは Phase 4 に到達したときだけ。** Phase 1〜3 は微増する（承認済み）
