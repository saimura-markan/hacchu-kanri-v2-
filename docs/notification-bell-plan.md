# E-Li 全通知統合ベル 実装計画書

**対象ファイル**: `index.html`（単一HTML / Babel standalone JSX、10,760行 / 558KB）
**作成日**: 2026-07-28
**ステータス**: 計画確定。コード変更・SQL実行は未着手。
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

#### 次回の再開地点

**`add_order_change_logs_read_by.sql` の STEP 2（backfill）から。**

- 271-286行 → **273-288行**（コメント2行追加により2行ずれている）のコメントを外し、
  **その UPDATE だけを選択して実行**する
- 7名の UUID を13件のログの `read_by` に投入する
- **第1回（STEP 0 / STEP 1 / STEP 1.5）は実行済み。再実行不要**
- 実行後 `UPDATE 13` を確認 → STEP 4（352行目以降）の確認 SELECT へ
- STEP 4 ②の「8名以上入った行」は除外方針決定前の基準でズレている。
  **「read_by が空の行 = 0」と ⑤のサンプル13行の要素数（7〜9）で判断する**

**Phase 1 の残り**: RPC 2本（`mark_message_read` / `mark_change_log_read`、§2-5）は未着手。

#### 未コミットのまま残す SQL ファイル 4本

| ファイル | 内容 | 実行状況 |
|---|---|---|
| `check_role_storage.sql` | ロール格納場所の調査（読み取り専用） | 実行済み |
| `check_is_system.sql` | `is_system` と `info@` の調査（読み取り専用） | 実行済み |
| `add_profiles_eli_notification_excluded.sql` | 通知除外列の追加 | 実行済み |
| `add_order_change_logs_read_by.sql` | `read_by` 追加・backfill・確認 | STEP 0/1/1.5 のみ実行済み |

Phase 1 が完了した時点でまとめてコミットする。

---

## 12. 将来拡張：メール通知（ベル完成後）

通知ベル（Phase 0〜5）が完成したあとに着手する。**現時点では未着手・未設計の記録のみ。**

### 目的

E-Li 上でアクションが発生したときに、顧客へメールで気づいてもらう。
ベルはログインしていないと見えないため、ログイン導線としてのメールが要る。

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
