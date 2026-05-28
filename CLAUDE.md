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
eli_img.png           イーライくんマスコット画像
logo_img.png          E-Liロゴ画像
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

| ロール | 説明 | アクセス先 |
|---|---|---|
| `user` | 一般お客様（デフォルト） | HistoryApp |
| `admin` | 管理者（全機能） | AdminApp |
| `staff` | スタッフ（削除ボタン非表示） | AdminApp |

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
const ELI_IMG  = "./eli_img.png";
const LOGO_IMG = "./logo_img.png";
```
base64埋め込みは削除済み（ファイルサイズ削減のため）。

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

- eli_img.png（LiBotキャラ）差し替え — 新しいキャラ画像ファイルを置いて差し替え
- ログイン画面デザイン改善 — UI刷新
- クレーム報告機能（ユーザーから管理者へのクレーム送信）
- 見積依頼機能（発注前の見積もり依頼フロー）
- 電話受注入力（管理者が電話受注を手動登録）
- ForgotScreen → `sb.auth.resetPasswordForEmail` への接続（現在はUI表示のみ）

---

## 変更履歴

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

### 2026-05-21 — チャットリアルタイム受信修正・Supabase本番認証

**コミット**: `36b7c05`, `0848d80`

#### 変更内容
- ChatScreen・AdminApp に3秒ポーリング追加（Supabase Realtime のフォールバック）
- `TEST_USERS` ダミーアカウント配列を削除
- `LoginScreen.handleLogin` を `sb.auth.signInWithPassword` による非同期認証に変更
- ロールは `data.user.user_metadata.role` から取得
- 本番デプロイ開始
