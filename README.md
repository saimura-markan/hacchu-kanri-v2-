# E-Li 工事受発注システム

> 24時間365日の発注受付・顧客/社内/協力会社の業務効率化を目的とした工事受発注Webアプリ。

- **本番URL:** https://hacchu-kanri-v2.vercel.app
- **本番稼働開始:** 2026-05-21
- **リポジトリ:** https://github.com/saimura-markan/hacchu-kanri-v2-.git

---

## システム概要

工事会社（株式会社マーカン）が提供する顧客向け発注受付システム。顧客は24時間いつでも工事の発注・日程確認・チャットでの問い合わせができる。社内スタッフはリアルタイムで受注確認・ステータス管理・顧客とのチャットを行える。

### システム目的

| 目的 | 内容 |
|---|---|
| 発注受付の自動化 | 電話・FAX依存からの脱却。顧客がWebで24時間発注可能 |
| コミュニケーション効率化 | チャット（LiBot自動返答含む）で担当者と直接やり取り |
| 案件管理の可視化 | ステータス管理・タイマー警告で対応漏れを防止 |
| 将来: 自動案件作成 | MK Connect連携により受注→社内案件作成を自動化（未実装） |

---

## 技術スタック

| 項目 | 採用技術 | 理由 |
|---|---|---|
| フロントエンド | React 18.2.0（CDN UMD版） | Node.js不要・サーバーレスで動作可能 |
| JSX変換 | @babel/standalone 7.23.6（ブラウザ内） | ビルドプロセスなし・デプロイが `git push` のみ |
| スタイル | インラインCSSオブジェクト + グローバルCSS | ファイル分割なし・単一HTML |
| 状態管理 | React useState / useEffect のみ | 外部ライブラリ不要 |
| DB・認証 | Supabase（PostgreSQL + Auth） | BaaS・RLSによるサーバーサイドアクセス制御 |
| ストレージ | Supabase Storage | 画像・PDFアップロード |
| メール送信 | Resend API（Supabase Edge Function経由） | パスワードリセットメールのみ使用 |
| ホスティング | Vercel | git push → 自動デプロイ |

### アーキテクチャの特徴（重要）

```
index.html（9,960行・単一ファイル）
├── <style>                           グローバルCSS
├── <script>                          ローダー・エラーハンドラー
└── <script type="text/jsx-source">   全Reactコード（JSX）
      ↓ babel.min.js がブラウザ内でコンパイル
      ↓ ReactDOM.createRoot で描画
```

**Node.js / npm / webpack 不要。** `index.html` を開くだけで動作する。  
`<script type="text/jsx-source">` という独自タグでJSXを記述し、ページロード時にBabelがコンパイルする。  
これによりエラーが「Script error.」に隠されず、画面上に詳細表示される利点がある。

---

## ローカル起動方法

```bash
cd ~/Documents/hacchu-kanri
python3 -m http.server 8080
```

- PC: http://localhost:8080
- スマホ（同一Wi-Fi）: http://192.168.24.41:8080

**必要なもの:** Python 3のみ。Node.js・npm・ビルド不要。

### デプロイ

```bash
git add index.html   # または変更したファイルを指定
git commit -m "変更内容"
git push origin main
# → Vercel が自動検知して本番反映（通常30秒〜2分）
```

---

## 環境変数・接続情報

### フロントエンド（index.html にハードコード）

```js
// index.html 310〜312行目
const SUPABASE_URL      = 'https://YOUR_PROJECT_ID.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
```

> Anonキーは公開鍵（フロントエンドに置くことが前提の設計）。  
> データアクセスはSupabaseのRow Level Security（RLS）で制御している。

### .env.local（Edge Functionのみ参照）

```
FROM_EMAIL=noreply@markan.co.jp
```

### Supabase Edge Function Secrets（Supabase Dashboard で管理）

| 変数名 | 用途 |
|---|---|
| `RESEND_API_KEY` | Resend APIキー（パスワードリセットメール送信） |
| `SERVICE_ROLE_KEY` | SupabaseサービスロールキーEdge Function内で使用） |

### ロール設定（管理者アカウントの設定方法）

```sql
-- Supabase Dashboard → SQL Editor で実行
UPDATE auth.users
SET raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}'::jsonb
WHERE email = 'xxx@markan.co.jp';
```

> **注意:** Dashboard の「Edit User」画面（user_metadata）ではなく、SQL Editor から `app_metadata` に設定すること。詳細は `docs/permissions.md` 参照。

---

## 主要機能

### 顧客（userロール）向け

| 機能 | 概要 |
|---|---|
| 発注フォーム | 4サービス区分（養生/解体/産廃/清掃）×複数日程・複数区分の同時発注 |
| 郵便番号→住所補完 | 入力中に住所を自動補完 |
| 現場名予測変換 | 過去に使用した現場名をキャッシュから予測表示 |
| 注文履歴 | ステータスフィルター・詳細確認 |
| チャット | 担当者・LiBotとのメッセージ（未読バッジ付き） |
| 日程変更依頼 | フォームから依頼 → 自動チャット投稿・ステータス変更 |
| キャンセル依頼 | ボタンから依頼 → 自動チャット投稿・ステータス変更 |
| 現場情報更新 | 鍵・駐車場・メモ・写真の追記 |
| マイページ | プロフィール編集・パスワード変更 |

### 社内スタッフ（admin/manager/staffロール）向け

| 機能 | 概要 |
|---|---|
| 受注一覧 | 検索・ステータスフィルター・優先度ソート |
| ステータス管理 | 7段階ステータスの変更・変更ログ自動記録 |
| タイマー警告 | 調整中（12/6/3h）・日程相談中（24〜72h）を色で警告 |
| 自動完了 | 終了時刻を過ぎると自動で「完了」へ遷移 |
| チャット | 顧客とのメッセージ・スタッフ間メンション・リプライ |
| 通知バッジ | 未読チャット・メンション・現場情報変更・変更ログを一覧カードに表示 |
| 日程編集 | 管理者が日程を変更 → 変更履歴を自動記録・顧客画面に表示 |
| ProWon連携 | 案件情報を整形してクリップボードコピー（手動連携） |
| 企業管理 | 企業IDの発行・有効/無効切替 |
| スタッフ管理 | スタッフの追加・編集・有効/無効切替 |
| 論理削除・復元 | 案件の削除（deleted_at）・復元 |

### LiBot自動メッセージ（5種類）

| トリガー | 送信内容 |
|---|---|
| 発注完了時 | 「受け付けました！24時間以内に...」 |
| 日程確定時（管理者操作） | 「【日程確定のご連絡】M月D日（曜日）H時〜H時」 |
| キャンセル確定時（管理者操作） | 「【キャンセル承認のご連絡】」 |
| キャンセル依頼時（顧客操作） | 「【キャンセルのご依頼】」 |
| 日程変更依頼時（顧客操作） | 「【日程変更のご依頼】現在/希望日程」 |

---

## 画面構成

```
[ログイン] ─── [パスワードリセット] ─── [新パスワード設定]
     │
     ├─ user ──→ [注文履歴]
     │               ├─→ [発注フォーム]（4サービス・複数日程）
     │               ├─→ [注文詳細]（キャンセル/日程変更依頼）
     │               │       └─→ [チャット]
     │               └─→ [マイページ]
     │
     └─ admin/manager/staff ──→ [管理者画面]
                                     ├─ 詳細パネル（詳細/チャット/プロワン用）
                                     ├─→ [企業ID管理]（adminのみ）
                                     ├─→ [スタッフ管理]（admin/manager）
                                     └─→ [削除済み案件]（adminのみ）
```

| コンポーネント | 行番号 | 対象ロール |
|---|---|---|
| `LoginApp` / `ForgotScreen` / `ResetPasswordScreen` | ~400〜870 | 全員 |
| `RegisterApp` | ~870〜1700 | 全員 |
| `OrderApp` | ~1700〜3600 | user |
| `HistoryApp` / `DetailScreen` / `ChatScreen` | ~3600〜6100 | user |
| `MyPageApp` | ~6100〜6500 | 全員 |
| `AdminApp` / `CompanyPanel` / `StaffPanel` / `DeletedPanel` | ~6900〜9960 | admin/manager/staff |

---

## 権限設計概要

| ロール | 画面 | 主な制限 |
|---|---|---|
| `user`（顧客） | HistoryApp / OrderApp / MyPage | 自社データのみ参照・管理者画面なし |
| `staff`（社内スタッフ） | AdminApp | ステータス変更・削除・企業/スタッフ管理不可 |
| `manager`（マネージャー） | AdminApp | スタッフ管理・削除済み復元・企業管理不可 |
| `admin`（管理者） | 全機能 | 制限なし |

### ロール設定場所

- ロールは `auth.users` の `app_metadata.role` に格納
- フロントエンドは `user_metadata.role` を参照（現状の実装）
- RLSポリシーは `app_metadata.role` を参照（`get_my_role()` 関数）

> **注意:** フロントエンドとRLSでロール参照先が異なる不整合がある。`docs/permissions.md` を必ず確認すること。

---

## データベース構成概要

```
companies（企業）
├── profiles（ユーザー） ← auth.users に紐づく
├── sites（現場情報）
│   └── site_history（現場情報変更履歴）
└── cases（案件 / KJ-xxx自動採番）
    └── orders（発注）
        ├── schedules（日程）
        │   └── schedule_history（日程変更履歴）
        ├── messages（チャット）
        ├── order_images（画像パス）
        ├── status_logs（ステータス変更ログ）
        └── order_change_logs（現場情報変更ログ）

staff（スタッフ ※ordersとの外部キーなし）
```

**Storageバケット:**
- `order-images` — 発注時の添付写真（パス: `{orderId}/{連番}.jpg`）
- `site-images` — 現場情報の写真・PDF

**SQLマイグレーション:** ルートディレクトリに `.sql` ファイルが29本。Supabase SQL Editorで手動実行する方式（自動マイグレーション管理なし）。

---

## MK Connect連携構想

> **現状: 未実装。コードに一切記述なし。**

### 目標

発注完了 → MK Connect上に案件を自動作成し、受注から案件管理までを自動化する。

### 現在の手動フロー（ProWon用コピー機能）

```
管理者が AdminApp の「📤 プロワン用」タブを開く
  ↓
案件情報を整形したテキストが表示される
  ↓
「全項目をコピーする」ボタン → クリップボードへ
  ↓
ProWon（社内システム）に手動ペースト・登録
```

### 将来の自動化構想

```
発注完了（saveToSupabase）
  ↓
cases テーブルに案件作成（case_code: KJ-001 等）
  ↓ ← ここにMK Connect API呼び出しを追加予定
MK Connect API（仕様・エンドポイント・認証方法 未定）
  ↓
MK Connect上に案件自動作成
```

### 連携実装に必要な確認事項

- [ ] MK Connect API エンドポイントの確認
- [ ] 認証方式（APIキー / OAuth 等）の確認
- [ ] 連携するデータ項目の定義（案件名・顧客情報・サービス種別等）
- [ ] エラー時のリトライ・通知の設計
- [ ] case_code（KJ-xxx）をMK Connect側の案件番号と紐づける設計

---

## docsフォルダ説明

```
docs/
├── system-overview.md    技術スタック・外部サービス・起動方法・デプロイ
├── business-flow.md      発注受付・ステータス遷移・チャット等のビジネスフロー
├── screens.md            全13画面の機能一覧・コンポーネント名・行番号
├── database-design.md    全テーブル定義・Storageバケット・SQLファイル一覧
└── permissions.md        ロール設計・RLS詳細・通知バッジ制御
```

各ファイルで ✅ 確認済み / ❌ 未実装 / ⚠️ 要確認 を明記している。

---

## 引継ぎ注意事項

### 1. コードは単一HTMLファイル（9,960行）

`index.html` にReact・スタイル・全コンポーネントが入っている。  
編集時は行番号を手がかりに目的のコンポーネントを探すこと（`CLAUDE.md` に行番号一覧あり）。  
コンポーネント間の衝突防止のためプレフィックスが付いている（`Hi`, `Or`, `AD`, `Rg`, `My`）。

### 2. SQLマイグレーションの適用状況が不明

ルートに `.sql` ファイルが29本あるが、どれがSupabaseに適用済みかを追跡する仕組みがない。  
新規環境を構築する場合は全SQLの適用が必要。既存本番環境では変更前にSupabase側の実態確認が必須。

### 3. RLSポリシーの不整合（セキュリティ注意）

フロントエンドのロール判定 → `user_metadata.role` を参照  
最新のRLSポリシー（`fix_rls_policies_comprehensive.sql`） → `app_metadata.role` を参照  

`fix_rls_policies_comprehensive.sql` がSupabase側に適用されているか要確認。  
未適用の場合、ユーザーが `supabase.auth.updateUser()` で自分のロールを書き換えられるリスクがある。

### 4. Resendドメイン認証の状況確認

パスワードリセットメールの送信元 `noreply@markan.co.jp` は、  
さくらインターネットのDNS側でResendのドメイン認証設定が必要。  
認証が完了していない場合、パスワードリセットメールが届かない可能性がある。

### 5. 3秒ポーリング（Supabase Realtime 未使用）

チャットとバッジ通知は3秒間隔のポーリングで実装されている。  
Supabase Realtimeは現在使用していない。同時接続ユーザーが多くなった場合の負荷に注意。

### 6. console.log が一部残存

`saveToSupabase` 内に `console.log` が残っている（本番でも出力される）。  
デバッグ目的のため意図的に残している可能性があるが、必要に応じて削除を検討する。

### 7. 参照用旧ファイル（TSX）はアプリ未使用

`v3-login.tsx`, `v4-admin-v2.tsx` 等は過去の開発中間ファイル。  
現在のアプリは `index.html` のみで動作しており、これらのTSXファイルはビルドもされない。

### 8. 既存ユーザーの company_id 未設定問題

一部の既存ユーザーで `profiles.company_id` が NULL のケースがある（fix_null_company_id.sql 参照）。  
マイページの企業ID表示が空欄になる場合、この問題が原因の可能性がある。

---

## 関連アカウント・サービス

| サービス | 用途 | 備考 |
|---|---|---|
| Supabase | DB・Auth・Storage・Edge Functions | プロジェクトID: Supabase Dashboard で確認 |
| Vercel | ホスティング | GitHubリポジトリと連携済み |
| Resend | メール送信 | ドメイン認証要確認 |
| GitHub | ソースコード管理 | `saimura-markan/hacchu-kanri-v2-` |
