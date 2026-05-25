# E-Li 工事受発注システム — CLAUDE.md

## プロジェクト概要

**E-Li（イーライ）工事受発注システム**  
工事会社向けの受発注・コミュニケーション管理Webアプリ。

- **形式**: 単一HTMLファイル（`index.html`）。Node.js不要、CDN React + Babel standaloneで動作。
- **場所**: `~/Documents/hacchu-kanri/`
- **ローカルサーバー起動**: `cd ~/Documents/hacchu-kanri && python3 -m http.server 8080`
  - PC: http://localhost:8080
  - スマホ（同一Wi-Fi）: http://192.168.24.41:8080

---

## ファイル構成

```
index.html    198KB  メインアプリ（全コード）
eli_img.png   2.2MB  イーライくんマスコット画像
logo_img.png  2.0MB  E-Liロゴ画像
v3-login.tsx          元ファイル（参照用、アプリ未使用）
v4-admin-v2.tsx
v4-history-v3.tsx
v4-mypage.tsx
v4-order-v8.tsx
v4-register-v2.tsx
```

---

## 技術スタック

| 項目 | 内容 |
|---|---|
| UI | React 18.2.0（UMD CDN） |
| JSX変換 | @babel/standalone 7.23.6（ブラウザ内コンパイル） |
| スタイル | インラインスタイル（CSS-in-JS） |
| 状態管理 | React useState / useEffect（コンポーネントローカル） |
| DB・API | なし（全データはメモリ上のstate） |
| 認証 | フロントエンドのみ（TEST_USERS配列） |

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
          └→ admin → 管理者画面     ↓
                               発注フォーム
```

---

## テストアカウント

| メール | パスワード | ロール |
|---|---|---|
| admin@test.com | 1234 | 管理者（AdminApp表示） |
| user@test.com | 1234 | 一般ユーザー（HistoryApp表示） |

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
- メール＋パスワードによるログイン
- ロール判定（admin / user）によって遷移先変更

### 発注フォーム（OrderApp）
- 作業区分選択 → 詳細入力（作業区分ごとに異なるフォーム）→ 確認 → 完了
- 複数日程・複数作業区分の追加対応
- 作業区分: 養生・家具移動・荷上 / 解体 / 産廃 / 清掃・家具移動

### 注文履歴（HistoryApp・ユーザー側）
- 一覧表示・ステータスフィルター
- 詳細画面（ステータス・基本情報・日程）
- チャット画面（イーライくん・担当者とのメッセージ）
- **キャンセル依頼**: ボタン→確認ダイアログ→チャット自動投稿＋ステータス変更
- **日程変更依頼**: ボタン→日付・時間入力フォーム→チャット自動投稿＋ステータス変更

### 管理者画面（AdminApp）
- 受注一覧（検索・フィルター・優先度ソート）
- 詳細パネル（ステータス変更・チャット・ProWon連携コピー）
- **ステータス変更**: 管理者のみ操作可能
- **タイマー警告**（管理者のみ表示）:
  - 調整中: 残り12h→薄黄 / 6h→オレンジ / 3h→赤点滅
  - 日程相談中: 経過24h→薄黄 / 36h→黄 / 48h→オレンジ / 60h→濃オレンジ / 72h→赤点滅
- **自動完了**: 予定日の終了時刻を過ぎると1分以内に「完了」へ自動遷移
- 企業ID管理（発行・一覧表示）

### チャット
- ユーザー側: 自分(user)のメッセージ右、担当者(staff)・イーライ(eli)は左
- 管理者側: 担当者(staff)のメッセージ右、その他は左
- 「日程確定」ステータス変更時に担当者からの自動メッセージ送信（作業内容・日時を含む）
- 未読バッジ表示

### マイページ（MyPageApp）
- プロフィール表示・編集
- パスワード変更モーダル

---

## 実装上の注意事項

### コンポーネントプレフィックスルール
各画面のコンポーネント・定数は衝突防止のため固有プレフィックスを付ける。
```
LoginApp: なし（共有コンポーネント含む）
RegisterApp: Rg（例: RgPrimaryBtn）
OrderApp: Or（例: OrBigBtn）
HistoryApp: Hi（例: HiOrderCard, HI_ORDERS, HI_STATUS）
MyPageApp: My（例: MyTopBar）
AdminApp: AD（例: ADStatusBadge, AD_ORDERS）
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

---

## 今後の追加候補（未実装）

- クレーム報告機能（ユーザーから管理者へのクレーム送信）
- 見積依頼機能（発注前の見積もり依頼フロー）
- 電話受注入力（管理者が電話受注を手動登録）
- ForgotScreen → `sb.auth.resetPasswordForEmail` への接続（現在はUI表示のみ）

---

## 次のタスク

1. **eli_img.png（LiBotキャラ）差し替え** — 新しいキャラ画像ファイルを置いて差し替え（logo_img.pngは2026-05-23済み）
2. **ログイン画面デザイン改善** — UI刷新
3. **アリリ隊キャラUI展開** — キャラクターを活用したUI演出

---

## 変更履歴

### 2026-05-23 — 画像・削除・復元・ロゴ対応

**コミット**: `63d2e5d`, `cf41348`, `11e660b`

#### 変更内容

**① 画像アップロード修正**
- Storage パスをシンプルな `${orderId}/${i}.jpg` に変更（日本語/スペース含むファイル名は Supabase Storage でサイレント失敗するため）
- `order_images` テーブルの insert カラム名を `storage_path` → `path` に修正（テーブル定義と一致させる）
- `saveToSupabase` に `images` を引数として明示渡し（stale closure 対策）
- `mapOrder` の画像マッピングも `img.path` に統一

**② お客様画面（HistoryApp）deleted_at フィルター**
- `fetchOrders` クエリに `.is('deleted_at', null)` を追加
- 論理削除済み案件がお客様側に表示されなくなった

**③ 削除済み案件パネル — 復元ボタン追加・複数選択修正**
- `DeletedPanel` の各行に「♻️ 復元」ボタンを追加（行ごとの単体復元）
- チェックボックスの複数選択バグ修正: `onChange` 方式 → カード全体 `onClick` + `e.stopPropagation()` パターンに変更（`AdOrderCard` と同じ実装に統一）

**④ E-Li ロゴ画像差し替え**
- `logo_img.png` を新デザイン（黒背景・青ロゴ）に差し替え
- `eli_img.png`（LiBotキャラ）は次回差し替え予定

---

### 2026-05-21 — チャットリアルタイム受信修正

**コミット**: `36b7c05`

#### 変更内容
- ChatScreen（ユーザー側）に3秒ポーリングを追加（Realtimeフォールバック）
- AdminApp の選択案件メッセージ useEffect にも同様の3秒ポーリングを追加
- Realtime `postgres_changes` は引き続き購読（即時性のため）
- ポーリングは重複防止 `id` チェック付き（同メッセージが二重表示されない）

#### 背景
Supabase Realtime の `postgres_changes` は RLS に `EXISTS` サブクエリや JWT メタデータを使うポリシーと組み合わせると、無音で失敗する場合がある。ポーリングを併用することで確実にメッセージを受信できる。

---

### 2026-05-21 — Supabase本物認証への切り替え

**コミット**: `0848d80`  
**リモート**: `https://github.com/saimura-markan/hacchu-kanri-v2-.git`（push済み）

#### 変更内容
- `TEST_USERS` ダミーアカウント配列を削除
- `LoginScreen.handleLogin` を `sb.auth.signInWithPassword` による非同期認証に変更
- ロールは `data.user.user_metadata.role` から取得（未設定時は `"user"` にフォールバック）
- ログイン中のローディング状態（`loading` state）を追加、ボタンを無効化して「ログイン中…」表示

#### Supabase ロール設定について
管理者ユーザーには Supabase ダッシュボード（Authentication → Users → Edit）で  
`user_metadata` に `{ "role": "admin" }` を設定する必要がある。  
一般ユーザーは設定不要（デフォルト `"user"`）。

#### Git push について
HTTPS push には GitHub PAT（Personal Access Token）が必要。  
scope: `repo` のトークンを `github.com/settings/tokens` で発行して使用。

## 2026-05-25 作業記録
### 本日完了
- 郵便番号→住所自動入力
- 番地・建物名欄追加
- 鍵🔑・駐車場🚗アイコン追加
- エアコン品番：直接入力/写真選択
- ハウスクリーニング図面あり/なし
- 現場名予測変換+顧客コード紐付け
- sitesテーブルにzip_codeカラム追加（Supabase）
- handleSiteSelect修正（zipCode+addrOk自動セット）
- git push → Vercelデプロイ完了（コミットf6d2c6d）

### 次の作業
1. saveToSupabaseにzip_code保存追加
2. デバッグ用console.log削除
3. 本番動作確認（Vercel）

## 2026-05-25 追加作業
### セキュリティ対応（完了）
- パスワードポリシー強化（8文字以上・英数字必須）
- 管理者画面保護（未ログインはログイン画面へリダイレクト）
- 環境変数確認（service_roleキーなし・問題なし）
- 日程ピッカー誤クローズ修正

### Googleフォーム（オーダーメモRPA対応版）
- GASのonFormSubmit関数にsortDescending()を追加
- 新しいフォーム送信が常に2行目（一番上）に来るように修正済み

### 次の作業
1. saveToSupabaseにzip_code保存追加
2. デバッグ用console.log削除
3. 本番動作確認（Vercel）
