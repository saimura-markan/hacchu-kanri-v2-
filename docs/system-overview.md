# E-Li システム概要

> 最終更新: 2026-06-15  
> ステータス凡例: ✅ 確認済み / ❌ 未実装 / ⚠️ 要確認

---

## プロジェクト基本情報

| 項目 | 内容 | ステータス |
|---|---|---|
| システム名 | E-Li（イーライ）工事受発注システム | ✅ 確認済み |
| 目的 | 24時間365日の発注受付・顧客・社内・協力会社の業務効率化 | ✅ 確認済み |
| 本番URL | https://hacchu-kanri-v2.vercel.app | ✅ 確認済み |
| 本番稼働開始 | 2026-05-21 | ✅ 確認済み |
| リポジトリ | https://github.com/saimura-markan/hacchu-kanri-v2-.git | ✅ 確認済み |

---

## 技術スタック

| 項目 | 内容 | ステータス |
|---|---|---|
| フロントエンド | React 18.2.0（CDN UMD版）| ✅ 確認済み |
| JSX変換 | @babel/standalone 7.23.6（ブラウザ内コンパイル） | ✅ 確認済み |
| スタイル | インラインCSSオブジェクト + グローバルCSS | ✅ 確認済み |
| 状態管理 | React useState / useEffect のみ | ✅ 確認済み |
| バックエンドDB | Supabase（PostgreSQL） | ✅ 確認済み |
| 認証 | Supabase Auth | ✅ 確認済み |
| ストレージ | Supabase Storage（order-images / site-images） | ✅ 確認済み |
| メール送信 | Resend API（Edge Function経由） | ✅ 確認済み |
| ホスティング | Vercel（git push → 自動デプロイ） | ✅ 確認済み |
| インフラ | AWS東京リージョン（ap-northeast-1） | ✅ 確認済み |

### 構成の特徴

```
index.html（単一ファイル）
├── <style>          グローバルCSS（ログイン画面・スクロールバー等）
├── <script>         ローダー・エラーハンドラー
└── <script id="jsx-source" type="text/jsx-source">
    ├── Supabase 初期化
    ├── 定数・カラーパレット
    ├── 共通コンポーネント
    ├── LoginApp / ForgotScreen / ResetPasswordScreen
    ├── RegisterApp
    ├── OrderApp
    ├── HistoryApp / DetailScreen / ChatScreen
    ├── MyPageApp
    ├── AdminApp / CompanyPanel / StaffPanel / DeletedPanel
    └── App（ルートコンポーネント）
```

- Node.js 不要。CDN から React・Babel・Supabase を読み込んでブラウザ内で動作する。
- `<script type="text/jsx-source">` に JSX を記述し、同一オリジンの `<script>` で手動コンパイル・実行。
- エラーが「Script error.」に隠されず、画面上に詳細表示される仕組み。

---

## Supabase 接続情報

| 項目 | 場所 | ステータス |
|---|---|---|
| SUPABASE_URL | index.html 310行目にハードコード | ✅ 確認済み |
| SUPABASE_ANON_KEY | index.html 311行目にハードコード | ✅ 確認済み |
| RESEND_API_KEY | Supabase Edge Function Secrets | ⚠️ 要確認（Supabase側で管理） |
| SUPABASE_SERVICE_ROLE_KEY | Supabase Edge Function Secrets | ⚠️ 要確認（Supabase側で管理） |
| FROM_EMAIL | .env.local（Edge Functionのみ参照） | ✅ 確認済み |

> **補足**: Anonキーは公開鍵のためフロントエンドへのハードコードは設計上の意図。Row Level Security（RLS）でデータアクセスを制御する。

---

## 外部サービス連携

| サービス | 用途 | ステータス |
|---|---|---|
| Supabase Auth | ユーザー認証・セッション管理 | ✅ 確認済み |
| Supabase Storage | 画像・PDFアップロード | ✅ 確認済み |
| Supabase Edge Functions | パスワードリセットメール送信 | ✅ 確認済み |
| Resend API | メール送信インフラ | ✅ 確認済み |
| Vercel | ホスティング・自動デプロイ | ✅ 確認済み |
| Resend ドメイン認証（markan.co.jp） | noreply@markan.co.jp からの送信 | ⚠️ 要確認（さくらインターネット側DNS設定が必要） |
| MK Connect | 受注→案件自動作成連携 | ❌ 未実装（計画のみ） |
| LINE通知 | ステータス変更・受注通知 | ❌ 未実装 |
| Slack通知 | 社内通知 | ❌ 未実装 |
| メール通知（受注・ステータス変更） | 顧客・担当者へのメール通知 | ❌ 未実装 |

---

## ローカル起動方法

```bash
cd ~/Documents/hacchu-kanri
python3 -m http.server 8080
# PC:     http://localhost:8080
# スマホ（同一Wi-Fi）: http://192.168.24.41:8080
```

---

## デプロイ方法

```bash
git add -A
git commit -m "変更内容"
git push origin main
# → Vercel が自動検知して本番反映（通常30秒〜2分）
```
