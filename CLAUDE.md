# E-Li 工事受発注システム — CLAUDE.md

## プロジェクト概要

**E-Li（イーライ）工事受発注システム**  
工事会社向けの受発注・コミュニケーション管理Webアプリ。

- **形式**: 単一HTMLファイル（`index.html`）。Node.js不要、CDN React + Babel standaloneで動作。
- **場所**: `~/Documents/hacchu-kanri/`
- **本番URL**: https://hacchu-kanri-v2.vercel.app（2026-05-21〜本番稼働中）
- **リモート**: https://github.com/saimura-markan/hacchu-kanri-v2-.git
- **ローカルサーバー起動**: `cd ~/Documents/hacchu-kanri && python3 -m http.server 8080`
  - PC: http://localhost:8080
  - スマホ（同一Wi-Fi）: http://192.168.24.41:8080

---

## ファイル構成

```
index.html            メインアプリ（全コード）
eli-guide.html        お客様ご利用ガイド
privacy-policy.html   プライバシーポリシー（/privacy-policy）
security-guide.html   セキュリティ・利用ガイド（/security）
vercel.json           Vercelルーティング設定
eli_img.webp          イーライくんマスコット画像（400×600 / 44KB）
logo_img.webp         E-Liロゴ画像（480×320 / 13KB）
ariri_yojo.webp       発注フォーム 作業区分アイコン（133×200 / 各12〜14KB）
ariri_barashi.webp
ariri_hakobii.webp
ariri_pikaai.webp
v3-login.tsx          元ファイル（参照用、アプリ未使用）
v4-admin-v2.tsx
v4-history-v3.tsx
v4-mypage.tsx
v4-order-v8.tsx
v4-register-v2.tsx
```

### vercel.json — URLルーティング
```json
{
  "rewrites": [
    { "source": "/privacy-policy", "destination": "/privacy-policy.html" },
    { "source": "/security",       "destination": "/security-guide.html" }
  ]
}
```

---

## 技術スタック

| 項目 | 内容 |
|---|---|
| UI | React 18.2.0（UMD CDN） |
| JSX変換 | @babel/standalone 7.23.6（ブラウザ内コンパイル） |
| スタイル | インラインスタイル（CSS-in-JS） |
| 状態管理 | React useState / useEffect（コンポーネントローカル） |
| DB・API | Supabase（PostgreSQL + Auth + Storage） |
| 認証 | Supabase Auth（`sb.auth.signInWithPassword`） |
| ホスティング | Vercel（git push で自動デプロイ） |
| インフラ | AWS東京リージョン（ap-northeast-1）、全サービスSOC2取得済み |

### Babel実行方式（重要）
`<script type="text/jsx-source">` にJSXを記述し、同一オリジンの `<script>` で手動コンパイル・実行。
これにより、エラーが「Script error.」に隠されず、画面上に詳細表示される。

---

## 画面構成・コンポーネント早見表

| 画面 | メインコンポーネント | 行番号 | プレフィックス |
|---|---|---|---|
| ログイン | `LoginApp` | ~92〜397 | なし |
| 新規登録 | `RegisterApp` | ~398〜862 | `Rg` |
| 発注フォーム | `OrderApp` | ~863〜2011 | `Or` |
| 注文履歴 | `HistoryApp` | ~2012〜2686 | `Hi` |
| マイページ | `MyPageApp` | ~2687〜3043 | `My` |
| 管理者 | `AdminApp` | ~3044〜3941 | `AD` |

### ナビゲーションフロー
```
ログイン ──→ user  → 注文履歴 ←→ マイページ
          └→ admin / staff → 管理者画面     ↓
                                        発注フォーム
```

---

## 認証・ロール

Supabase Auth で認証済み。ロールは `user_metadata.role` で管理。

> ⚠️ **【2026-07-31 追記】この記述はコードと食い違っている。**
> 実際にロールを読んでいる箇所はすべて **`app_metadata.role`**:
> `index.html:529`（ログイン）/ `10345`（`AdminApp` の init ゲート）/
> `10941`（`onAuthStateChange`）。既知の「ロール二重管理の食い違い」の一部。
> どちらが正なのかを確定していないため、記述は残したうえで注記に留める。

| ロール | 説明 | アクセス先 |
|---|---|---|
| `user` | 一般お客様（デフォルト） | HistoryApp |
| `admin` | 管理者（全機能） | AdminApp |
| `staff` | スタッフ（削除ボタン非表示） | ⚠️ 下記参照 |

> ⚠️ **【2026-07-31 追記】`staff` は現行コードでは `AdminApp` に到達できない。**
> 関門が3つあり、いずれも `admin` / `manager` だけを通す:
> `index.html:10957`（`handleLogin`）/ `10943-10947`（`onAuthStateChange`）/
> `10345`（`AdminApp` init。該当外は `onLogout()`）。
> ログイン自体は通り、顧客画面（履歴）に着地する。
> 上表の「staff → AdminApp」は実態と異なる。

### 管理者アカウント（本番）
- saimura@markan.co.jp
- info@markan.co.jp
- nakata@markan.co.jp
- demo@markan.co.jp

### ロール設定方法
Supabase ダッシュボード → Authentication → Users → Edit → `user_metadata` に設定：
```json
{ "role": "admin" }
```
一般ユーザーは設定不要（未設定時は `"user"` にフォールバック）。

---

## データ構造

### 注文（HI_ORDERS / AD_ORDERS）
```js
{
  id: "B-2024-101",
  service: "養生・家具移動・荷上",
  status: "日程確定",
  site: "〇〇マンション101号室",
  address: "大阪府...",
  zip_code: "532-0004",
  schedules: [{ date:"2026-05-22", start:"09:00", end:"17:00", workers:"3人", details:[...] }],
  key: "管理室で受取",
  parking: "建物前2台",
  note: "",
  created: "2024-06-10 17:32",
  createdAt: Date.now() - 2*3600000,      // タイマー用Unixms
  statusChangedAt: Date.now() - 1*3600000 // タイマー用Unixms
}
```

### ステータス一覧（HI_STATUS）
| ステータス | 色 | 用途 |
|---|---|---|
| 調整中 | 黄 | 受付直後 |
| 日程確定 | 青 | 日程が決定 |
| 日程相談中 | オレンジ | 日程を調整中 |
| 日程変更相談中 | 紫 | ユーザーが日程変更依頼 |
| キャンセル相談中 | 薄赤 | ユーザーがキャンセル依頼 |
| 完了 | 緑 | 工事完了 |
| キャンセル | 赤 | キャンセル確定 |

### チャットメッセージ
```js
{ id: Date.now(), from: "user"|"staff"|"eli", text: "...", time: "14:30", read: true }
```

---

## 実装済み機能

### 認証
- Supabase Auth による本番認証（`sb.auth.signInWithPassword`）
- ロール判定（admin / staff / user）によって遷移先変更
- パスワードポリシー：8文字以上・英数字必須
- 管理者画面保護（未ログインはログイン画面へリダイレクト）

### 発注フォーム（OrderApp）
- 作業区分選択 → 詳細入力（作業区分ごとに異なるフォーム）→ 確認 → 完了
- 複数日程・複数作業区分の追加対応
- 作業区分: 養生・家具移動・荷上 / 解体 / 産廃 / 清掃・家具移動
- 郵便番号入力で住所自動補完
- 現場名予測変換＋顧客コード紐付け（sitesテーブル）
- エアコン品番：直接入力/写真選択
- ハウスクリーニング：図面あり/なし

### 注文履歴（HistoryApp・ユーザー側）
- 一覧表示・ステータスフィルター
- 詳細画面（ステータス・基本情報・日程・鍵・駐車場・注意事項・写真）
- チャット画面（イーライくん・担当者とのメッセージ）
- **キャンセル依頼**: ボタン→確認ダイアログ→チャット自動投稿＋ステータス変更
- **日程変更依頼**: ボタン→日付・時間入力フォーム→チャット自動投稿＋ステータス変更
- フッターにプライバシーポリシー・セキュリティリンク表示
- deleted_at フィルター（論理削除済み案件は非表示）

### 管理者画面（AdminApp）
- 受注一覧（検索・フィルター・優先度ソート）
- 詳細パネル（ステータス変更・チャット・ProWon連携コピー）
- **ステータス変更**: 管理者のみ操作可能
- **タイマー警告**（管理者のみ表示）:
  - 調整中: 残り12h→薄黄 / 6h→オレンジ / 3h→赤点滅
  - 日程相談中: 経過24h→薄黄 / 36h→黄 / 48h→オレンジ / 60h→濃オレンジ / 72h→赤点滅
- **自動完了**: 予定日の終了時刻を過ぎると1分以内に「完了」へ自動遷移
- 企業ID管理（発行・一覧表示）
- 削除済み案件パネル（復元ボタン・複数選択）
- staffロール：削除ボタン非表示
- **統合通知ベル 🔔**（2026-07-31）: サイドバーの 🔔 に未読数バッジ。
  クリックでドロワーが開き、@メンション / 💬 チャット / 🔔 変更ログを
  1つのフィードで一覧。項目クリックで該当案件を開いて既読になる。
  一覧カードのバッジもこのフィードから算出しており、両者は必ず同期する

### チャット
- ユーザー側: 自分(user)のメッセージ右、担当者(staff)・イーライ(eli)は左
- 管理者側: 担当者(staff)のメッセージ右、その他は左
- 「日程確定」ステータス変更時に担当者からの自動メッセージ送信（作業内容・日時を含む）
- 未読バッジ表示
- 3秒ポーリング（Supabase Realtime のフォールバック）

### マイページ（MyPageApp）
- プロフィール表示・編集
- パスワード変更モーダル

### 案件・現場管理
- 現場情報（鍵・駐車場・注意事項）のスマホからの追記
- 写真・PDFアップロード（site-imagesバケット）
- sitesテーブルに zip_code・メモ保存

### 静的ページ
- `/privacy-policy` → `privacy-policy.html`：プライバシーポリシー
- `/security` → `security-guide.html`：セキュリティ・利用ガイド
- `eli-guide.html`：お客様ご利用ガイド（SOC2セキュリティバッジ含む）

---

## 実装上の注意事項

### コンポーネントプレフィックスルール
各画面のコンポーネント・定数は衝突防止のため固有プレフィックスを付ける。
```
LoginApp:    なし（共有コンポーネント含む）
RegisterApp: Rg（例: RgPrimaryBtn）
OrderApp:    Or（例: OrBigBtn）
HistoryApp:  Hi（例: HiOrderCard, HI_ORDERS, HI_STATUS）
MyPageApp:   My（例: MyTopBar）
AdminApp:    AD（例: ADStatusBadge, AD_ORDERS）
```

### 画像パス
```js
const ELI_IMG    = "./eli_img.webp";
const LOGO_IMG   = "./logo_img.webp";
const ARIRI_YOJO    = "./ariri_yojo.webp";
const ARIRI_KAITAI  = "./ariri_barashi.webp";
const ARIRI_SANPAI  = "./ariri_hakobii.webp";
const ARIRI_SOUJI   = "./ariri_pikaai.webp";
```
base64埋め込みは削除済み（ファイルサイズ削減のため）。

**画像を差し替えるときの注意（2026-07-30）**
- **WebP 単体。PNG フォールバックは持たない**（iOS14+/Android で対応済み）。
  `<picture>` を導入すると48箇所の `<img>` を触ることになり、
  定数6行の差し替えで済む利点が消えるため採用しない。
- **参照は `index.html` だけではない。** `eli-guide.html`（4箇所）・
  `privacy-policy.html`（2箇所）・`security-guide.html`（2箇所）も
  同じファイルを直接参照している。差し替え時は4ファイル全部を直すこと。
- サイズは「最大表示サイズ × 2（Retina）」。最大表示は
  `eli_img`=300px（`.login-libot` / eli-guide `.hero-libot`）、
  `logo_img`=160px、`ariri_*`=100px（`index.html:2300` の1箇所のみ）。
- **`ariri_*` は `mixBlendMode:"multiply"` で合成される。** lossy 圧縮の
  エッジのにじみが色付き輪郭として出るため、他より品質を上げる（q=90）。
- 変換手段は `sharp`（npm）。このマシンは `cwebp`・Homebrew が未インストールで、
  `sips` は WebP を書けない。

### role の受け渡し
`App` → `HistoryApp(role)` → `DetailScreen(role)` / `ChatScreen(role)` / `HiOrderCard(role)`

### ステータス変更フロー（HistoryApp）
```
handleStatusChange(id, newStatus)
  → setOrders（状態更新）
  → statusChangedAt 記録
  → "日程確定"の場合: チャットに作業内容・日時を含む自動メッセージ送信
```

### 自動完了（useEffect）
`HistoryApp` マウント時に60秒インターバルで `schedules[0].date + end` と現在時刻を比較し、
過去になっていたら自動で「完了」ステータスへ変更。

### 画像アップロード（Storage）
- パス: `${orderId}/${i}.jpg`（日本語・スペース含むファイル名は Supabase Storage でサイレント失敗するため）
- テーブル: `order_images`、カラム: `path`
- `saveToSupabase` に `images` を引数として明示渡し（stale closure 対策）

---

## 今後の追加候補（未実装）

- eli_img.webp（LiBotキャラ）差し替え — 新しいキャラ画像ファイルを置いて差し替え（上記「画像を差し替えるときの注意」を参照）
- ~~ロゴ・キャラ画像の最適化~~ → **2026-07-30 完了**（配信 12.79MB → 108.6KB / 99.17%減）。詳細は `docs/notification-bell-plan.md` §11「2026-07-30」
- ログイン画面デザイン改善 — UI刷新
- クレーム報告機能（ユーザーから管理者へのクレーム送信）
- 見積依頼機能（発注前の見積もり依頼フロー）
- 電話受注入力（管理者が電話受注を手動登録）
- ForgotScreen → `sb.auth.resetPasswordForEmail` への接続（現在はUI表示のみ）

---

## 変更履歴

### 2026-08-01 — 顧客メール通知（日程確定）本番稼働

**`index.html` は無変更。**DB トリガー＋Edge Function のみで実現している。

詳細な設計判断・教訓・積み残しは `docs/notification-bell-plan.md` §11「2026-08-01」に記録。

#### 構成

```
orders.status → 日程確定
  → trg_eli_notify_schedule_fixed（AFTER UPDATE OF status）
  → net.http_post（pg_net・非同期）
  → Edge Function send-order-notification（Verify JWT OFF）
  → Resend
```

#### 追加したもの

| 種別 | 名前 |
|---|---|
| ソース控え | `edge-function-send-order-notification.ts` |
| マイグレーション | `add_email_notification_schedule_fixed.sql` |
| テーブル | `public.eli_email_log`（送信ログ。宛先はドメインのみ保存） |
| 関数 | `public.eli_notify_schedule_fixed()`（SECURITY DEFINER） |
| トリガー | `trg_eli_notify_schedule_fixed` on `public.orders` |
| Vault | `eli_notify_secret` / `eli_notify_url` |
| Function Secrets | `ELI_NOTIFY_SECRET` / `APP_URL`（追加）|

#### 注意事項

- **シークレットは1つの値を Vault と Edge Function の両方に貼ること。**
  別々に生成すると `401 unauthorized` になる
- **トリガー関数は `EXCEPTION WHEN OTHERS` で例外を握り潰す。**
  業務操作を止めないための設計だが、異常時に `net._http_response` が0行になり
  「発火していない」ように見える。切り分けは `net.http_post` を直接叩く
- メール本文に案件情報を載せない方針（確定日付も書かない）
- 自動完了ループ（`index.html:10443`）は `完了` にするだけなのでこのトリガーは
  発火しない。全管理者のブラウザで60秒ごとに走る箇所なので、
  ここに送信を足していたら端末数だけ重複送信になっていた
- **キャリアメール（`@docomo.ne.jp` 等）には未着。**
  Resend のドメイン認証（SPF/DKIM）未完了が原因。Gmail には着信確認済み

#### 既知の別件バグ（未対応）

**`cases` の RLS がアプリと別の場所を見ている。**
アプリは `user_companies.is_primary` → `profiles.company_id` の順で会社を解決するが
（`index.html:3276-3290`）、`cases` の RLS は `profiles.company_id` しか見ない
（`fix_cases_rls_insert.sql:11-17`）。`user_companies` にだけ紐付けがあるユーザーは
発注時に RLS 違反になる。根本対応は別タスク。

### 2026-07-31 — 統合通知ベル（管理者側）Phase 2 完了・Phase 3 主要部完了

**コミット**: `dbd7ebc`（本番デプロイ済み・byte 一致で確認）

詳細な設計判断と積み残しは `docs/notification-bell-plan.md` §11「2026-07-31」に記録。

#### 追加した機能
- サイドバー 📋 直下に 🔔（未読数バッジ付き・100件超は `99+`）
- 通知パネル `AdNotifPanel`（ドロワー・`left:60 / width:360`）。
  フィルタチップ（すべて / @メンション / 💬 チャット / 🔔 変更）・空状態・
  相対時刻・本文抜粋（60字）
- 通知クリックで**該当案件を開く → タブを選ぶ → 既読**。
  遷移は `openNotification()` の1本のみを通す
- 「すべて既読」（確認ダイアログ付き）

#### 既存挙動の変更
- 一覧カードのバッジ（💬 / @ / 🔔）を通知フィード由来に統一。
  ベルとカードが必ず同期する
- **💬 バッジの意味が広がった。** 統合前はお客様メッセージのみ、
  統合後はスタッフ間メッセージ（自分宛メンション以外）も含む
- 変更ログのバッジを `confirmed_by IS NULL`（誰も確認していない）から
  `read_by`（自分が読んでいない）に変更。
  あわせて「✅ 確認済みにする」でも `read_by` を打つようにした
- 「要対応（調整中・相談中）」バッジを 🗑️ 直下から 📋 直後へ移動し
  `title` を付与（ゴミ箱の通知と誤読される位置だったため）
- 通知ポーリングのクエリを 4本 → 3本に削減

#### 注意事項
- **`from_role='eli'`（LiBot）は通知クエリから必ず除外すること。**
  LiBot の自動メッセージは `sender_id` を持たないまま insert されるため
  （`index.html:4553` / `10477` ほか）、除外しないと
  `sender_id.is.null` の条件に全件が引っかかり全管理者に通知が飛ぶ
- 通知クエリには `.limit(100)` が付いている。
  未読が各テーブル100件を超えるとバッジも100で頭打ちになる
- チャット通知を1件クリックすると、既存の案件一括既読
  （`index.html:7622-7625` → `markChatRead`）により
  同案件の他のチャット通知もまとめて消える（仕様）
- `fetchNotifications()` は `useEffect([])` から呼ばれるため
  `orders` は `ordersRef` 経由で読む。state から読むと空配列に固定される

#### 未実装
- 欄内スクロール（該当メッセージ・該当ログへの移動）とハイライト演出
- 顧客側のベル（Phase 4）

---

### 2026-05-28 — ポリシーページ・バグ修正・発注フロー強化・日程変更履歴・LiBot自動メッセージ

**コミット**: `38437fe`, `cff7ed9`, `2cc3fe6`, `08866f7`, `49b5bc9`, `a20de38`, `5d2c77a`, `fe39261`, `2ddeb8d`, `364cc12`, `580ab65`, `67eedf7`, `7d16868`, `ef69f35`, `799c598`, `2832b15`, `fb293c7`, `e6a795d`

#### 静的ページ・ガイド対応
- `privacy-policy.html` 追加（/privacy-policy）：運営会社・収集情報・インフラ・お客様の権利など
- `security-guide.html` 追加（/security）：SOC2バッジ・認証・パスワード・禁止事項・問題発生時の対応
- `vercel.json` 追加：URLリライト設定（/privacy-policy・/security）
- `eli-guide.html`：SOC2セキュリティバッジセクション追加・OGPタグ・Twitter Card追加
- `index.html`（HistoryApp）：フッターにプライバシーポリシー・セキュリティリンク追加

#### 発注エラー修正
- profiles insert から存在しない `company` カラムを削除（登録時エラー②解消）
- orders insert に `user_id` を追加（FK違反エラー①解消）
- `saveToSupabase` 内で `sb.auth.getUser()` を直接呼び出し、stale closure による `userId=null` を防止
- profiles 行が未作成のユーザーは発注時に `upsert` で自動作成
- profiles クエリを `.single()` → `.maybeSingle()` に統一（406エラー解消）

#### 発注フォーム改善
- 日付ピッカーに `min=今日` を追加（過去日付の選択不可）
- 担当者欄に `personNameLoading` state を追加（取得中は「取得中」を表示）
- ログイン時に `profiles.name` が空の場合、メールアドレスの @前を仮名として自動 upsert

#### 氏名・ふりがな4フィールド対応
- 登録フォーム Step2：氏名1フィールド → 姓/名（漢字）・姓/名（ふりがな）の横並び2列×2行
- profiles 保存：`name = 姓+' '+名`、`name_kana = 姓ふりがな+' '+名ふりがな`
- マイページ担当者名も同様に4フィールド分割（スペース分割で初期表示）
- `add_name_kana.sql` 追加：`profiles.name_kana`・`orders.person_kana` カラム追加 SQL

#### 管理者画面・マイページ改善
- 管理者画面 orders クエリに `profiles(name, name_kana)` の FK JOIN を追加
- `orders.person` が空の場合 `profiles.name` をフォールバック表示
- 管理者 案件詳細に「ふりがな」行を追加
- マイページ：企業名を `companies` テーブルから取得、`company_id` を orders からフォールバック

#### LiBot自動メッセージ（全5種類）
- 新規発注完了時：`受け付けました！` を LiBot として自動送信
- 日程確定時（管理者操作）：`【日程確定のご連絡】確定日程（M月D日（曜日）H時〜H時）` を自動送信
- キャンセル確定時（管理者操作）：`【キャンセル承認のご連絡】` を自動送信
- キャンセル依頼時（お客様操作）：`【キャンセルのご依頼】` を自動送信
- 日程変更依頼時（お客様操作）：`【日程変更のご依頼】現在の日程・ご希望の日程` を自動送信
- `handleStatusChange` を async 化し、日程確定・キャンセル時に Supabase へ直接保存

#### 日程変更履歴機能
- `add_schedule_history.sql` 追加：`schedule_history` テーブル定義・RLSポリシー
- 管理者が日程編集保存時、日付・時間の変更を自動検出して `schedule_history` へ保存
- 管理者画面の日程カード：「変更あり」バッジ・「（変更後）」表示・変更前日程を履歴セクションで確認可
- お客様の注文履歴画面の日程カード：同様に「変更あり」バッジ・変更前日程を紫ボックスで表示
- fetchOrders クエリを `schedules(*, schedule_history(*))` に更新（両画面）

#### 次回課題
- マイページの企業ID表示（既存ユーザーの `company_id` 復旧）
- `schedule_history` RLSポリシーのSupabase側での適用確認

---

### 2026-05-26 — 案件管理・staffロール対応

**コミット**: 複数

#### 変更内容
- zip_code保存追加（sitesテーブル）
- console.log削除
- Vercel本番動作確認
- staffロール追加（削除ボタン非表示・admin画面アクセス可）
- 案件ページ・詳細表示追加
- メモ・注意事項追記（sitesテーブルに現場単位で保存）
- 写真・PDF添付（site-imagesバケット作成・RLS設定済み）

---

### 2026-05-25 — 発注フォーム強化・セキュリティ対応

#### 変更内容
- 郵便番号→住所自動入力
- 番地・建物名欄追加
- 鍵🔑・駐車場🚗アイコン追加
- エアコン品番：直接入力/写真選択
- ハウスクリーニング図面あり/なし
- 現場名予測変換+顧客コード紐付け
- sitesテーブルにzip_codeカラム追加（Supabase）
- パスワードポリシー強化（8文字以上・英数字必須）
- 管理者画面保護（未ログインはログイン画面へリダイレクト）
- 日程ピッカー誤クローズ修正

---

### 2026-05-23 — 画像・削除・復元・ロゴ対応

**コミット**: `63d2e5d`, `cf41348`, `11e660b`

#### 変更内容
- Storage パスをシンプルな `${orderId}/${i}.jpg` に変更
- `order_images` テーブルのカラム名を `storage_path` → `path` に修正
- `saveToSupabase` に `images` を引数として明示渡し（stale closure 対策）
- `fetchOrders` クエリに `.is('deleted_at', null)` を追加（論理削除済み案件を非表示）
- `DeletedPanel` に復元ボタン追加・複数選択バグ修正
- `logo_img.png` を新デザインに差し替え

---

## 次回タスク（2026-06月〜）
- Seed Note構築（6月中完成目標）

---

### 2026-05-31 — ResetPasswordScreen・ロール権限・チャット改修

**コミット**: `da9c3ca`, `f21e7f6`, `1f885e8`, `df6ad5d`, `74f8ab3`, `1690982`, `934fb6f`

#### ①ResetPasswordScreen実装・動作確認完了
- URLハッシュから `access_token` / `refresh_token` を取得し `setSession()` でセッション設定
- JWT issued at future エラー対策: `setSession()` 前に1秒待機（setTimeout）
- フォームを即座に表示しバックグラウンドで `setSession()` → ボタンは「準備中...」で無効化
- `updateUser({ password })` で新パスワードに更新 → 完了後 `signOut()` → ログイン画面へ
- `App` の `onAuthStateChange` に `PASSWORD_RECOVERY` イベント処理を追加
- `ResetPasswordScreen` 表示中はサインアウト時も画面を維持

#### ②Resendドメイン認証（業者に依頼メール送付済み・返信待ち）
- ネームサーバー: `ns1.dns.ne.jp` / `ns2.dns.ne.jp`（さくらインターネット）
- 認証完了後: Edge Functionの `FROM_EMAIL` を `noreply@markan.co.jp` に変更してデプロイ

#### ③staffテーブル作成・RLS設定（`add_staff_table.sql`）
- カラム: `id` / `name` / `role` / `phone` / `email` / `is_active` / `created_at`
- RLS: admin=全操作、staff=自分のメール一致行のみSELECT
- 管理画面サイドバーに👷ボタン追加（adminのみ）→ StaffPanelモーダル
- 一覧・追加・編集・有効/無効切替・削除

#### ④ロール別権限実装（admin/manager/staff）
- admin: 全機能（スタッフ管理👷・企業ID管理🏢・削除🗑️含む）
- manager: adminとほぼ同じ（スタッフ管理👷のみ非表示）
- staff: 発注一覧・案件詳細・チャットのみ（🏢・👷・🗑️・削除ボタン非表示）
- ロール選択肢を admin/manager/staff に変更（worker → manager）

#### ⑤ステータス変更権限・変更ログ（`add_status_logs_table.sql`）
- ステータス変更セレクト・編集ボタン: admin/managerのみ表示
- `status_logs` テーブル: `order_id` / `changed_by` / `old_status` / `new_status` / `changed_at`
- `handleStatusChange` / `handleEdit` でfire-and-forgetでINSERT（ログ記録）
- DetailPanel詳細タブに「📝 ステータス変更ログ」として逆順表示

#### ⑥E-Liチャット改修（`alter_messages_for_chat.sql`）
- `messages` テーブルに `reply_to_id` / `mentions` / `read_by` カラム追加
- `mark_messages_read` RPC追加（一括既読登録）
- リプライ: 「↩ 返信」ボタン→引用プレビュー→`reply_to_id`をDB保存→吹き出し上部に引用表示
- メンション: `@テキスト` をハイライト表示（青背景・太字）、`mentions[]`に配列保存
- 既読確認: チャットタブを開くとRPCで一括既読登録、担当者メッセージに「既読 N」表示
- LiBot自動返答: ユーザー送信後・直前がeli以外なら0.9秒後に定型文を自動送信

---

### 2026-05-21 — チャットリアルタイム受信修正・Supabase本番認証

**コミット**: `36b7c05`, `0848d80`

#### 変更内容
- ChatScreen・AdminApp に3秒ポーリング追加（Supabase Realtime のフォールバック）
- `TEST_USERS` ダミーアカウント配列を削除
- `LoginScreen.handleLogin` を `sb.auth.signInWithPassword` による非同期認証に変更
- ロールは `data.user.user_metadata.role` から取得
- 本番デプロイ開始

---

### 2026-06-04 — 管理者画面サイドバー通知バッジ・現場情報更新履歴

#### ①通知バッジ（`AdOrderCard`）
- お客様の未読チャット件数が赤バッジ「💬 N件未読」としてカード下部に表示（ポーリング3秒）
- お客様が現場情報を変更・追加すると橙バッジ「📋 現場情報更新」が表示
- 管理者が案件を開くと現場情報更新バッジは即時消去（`seen_by_admin=true` に更新）
- チャットを既読にすると未読バッジも即時消去（`markChatRead` 内で `unreadCounts` を即時更新）

#### ②現場情報の変更履歴（`site_history` テーブル）
- `add_site_history.sql` 追加：`site_history` テーブル定義・RLSポリシー
  - カラム: `order_id` / `company_id` / `site_name` / `changed_by` / `field_name` / `field_label` / `old_value` / `new_value` / `seen_by_admin` / `changed_at`
- お客様が「💾 保存する」ボタンを押すと変更フィールドを自動検出してDB記録
- 写真アップロード時も site_history に記録
- 管理者の詳細パネル（詳細タブ）に「🔄 現場情報の更新履歴」として表示（降順）
  - 変更前→変更後の値・項目名・日時を表示

#### Supabase実行SQL
`add_site_history.sql` を Supabase SQL Editor で実行してください。
