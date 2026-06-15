# E-Li 障害復旧手順書

> 作成日: 2026-06-15  
> 対象: GitHub喪失 / PC喪失 / Supabase喪失 の3ケース

---

## 環境変数・接続情報 完全一覧

### フロントエンド（index.html にハードコード）

| 変数名 | 値 | 管理場所 |
|---|---|---|
| `SUPABASE_URL` | `https://wxjmqrxaqrujsvgzknwy.supabase.co` | index.html 310行目 |
| `SUPABASE_ANON_KEY` | `sb_publishable_JYkjSrSixBp9jquMeq6hKw_YMwwiDSx` | index.html 311行目 |

> Anonキーは公開鍵。フロントエンドに置くことが設計上の前提。  
> データは Supabase RLS（Row Level Security）で保護する。

### .env.local（Gitに含まれない・ローカルのみ）

| 変数名 | 値 | 用途 |
|---|---|---|
| `FROM_EMAIL` | `noreply@markan.co.jp` | Edge Function参照用（現在は直接コード内に記載） |

> .env.local は .gitignore に含まれており、GitHubには存在しない。  
> Edge Functionのメール送信元は `edge-function-send-reset-email.ts` 内にも直接記載されている。

### Supabase Edge Function Secrets（Supabase Dashboard で管理）

| 変数名 | 用途 | 取得元 |
|---|---|---|
| `RESEND_API_KEY` | Resend APIキー（パスワードリセットメール） | Resend ダッシュボード → API Keys |
| `SERVICE_ROLE_KEY` | Supabaseサービスロールキー（管理者API） | Supabase Dashboard → Settings → API |

> これらはSupabase側にのみ存在する。コードにもGitにも含まれない。

### 本番管理アカウント

| サービス | アカウント | 補足 |
|---|---|---|
| Supabase | saimura@markan.jp | プロジェクトID: `wxjmqrxaqrujsvgzknwy` |
| Vercel | saimura@markan.jp | GitHubリポジトリと連携済み |
| GitHub | saimura-markan | リポジトリ: `hacchu-kanri-v2-` |
| Resend | saimura@markan.jp | ドメイン: markan.co.jp |

---

## Supabaseバックアップ手順

### データバックアップ（手動）

Supabase は無料プランの場合、自動バックアップがない。  
定期的に以下の手順でデータをエクスポートすること。

#### テーブルデータのエクスポート

```
Supabase Dashboard
→ Table Editor
→ 各テーブルを開く
→ 右上「Export」→「Download as CSV」
```

または SQL Editor で実行：

```sql
-- 主要テーブルをCSV出力（SQL Editor → 結果をExport）
SELECT * FROM orders    ORDER BY created_at DESC;
SELECT * FROM companies ORDER BY id;
SELECT * FROM profiles  ORDER BY updated_at DESC;
SELECT * FROM sites     ORDER BY created_at DESC;
SELECT * FROM messages  ORDER BY created_at DESC;
SELECT * FROM cases     ORDER BY created_at DESC;
SELECT * FROM staff     ORDER BY created_at DESC;
```

#### Storageバックアップ

```
Supabase Dashboard → Storage
→ order-images バケット → 各フォルダを個別ダウンロード
→ site-images  バケット → 各フォルダを個別ダウンロード
```

> 画像の自動バックアップ手段は現状なし。重要な現場写真は別途クラウドストレージ（Google Drive等）にも保存することを推奨。

### SQLスキーマのバックアップ

スキーマ（テーブル定義・RLSポリシー）はすべて `.sql` ファイルとしてGitHubに保存済み。  
GitHubが生きていれば、スキーマは常に復元可能。

---

## ケース1: GitHubリポジトリを失った場合

### 状況

- リポジトリが誤って削除された
- アカウントがロックされた
- リモートへのアクセスが失われた

### 影響範囲

| 影響 | 内容 |
|---|---|
| コード | Vercelにデプロイ済みのコードは生きている |
| 自動デプロイ | git push → Vercel の自動デプロイが止まる |
| SQLファイル | ローカルに存在する（`~/Documents/hacchu-kanri/*.sql`） |

### 復旧手順

**Step 1: ローカルのコードが無事か確認**

```bash
ls ~/Documents/hacchu-kanri/index.html
git log --oneline -5   # ローカルにコミット履歴があるか確認
```

**Step 2: 新しいGitHubリポジトリを作成**

```
GitHub → New repository
リポジトリ名: hacchu-kanri-v2-（または任意の名前）
Visibility: Private
```

**Step 3: ローカルのリモートを新しいリポジトリに変更**

```bash
cd ~/Documents/hacchu-kanri
git remote set-url origin https://github.com/saimura-markan/【新リポジトリ名】.git
git push -u origin main
```

**Step 4: Vercelの連携を新しいリポジトリに変更**

```
Vercel Dashboard → プロジェクト設定 → Git
→ Disconnect → 新しいリポジトリを再接続
```

**Step 5: 動作確認**

```bash
git push origin main   # Vercel が自動デプロイされるか確認
# 本番URL: https://hacchu-kanri-v2.vercel.app
```

### 復旧所要時間の目安

ローカルコードが無事な場合: **15〜30分**

---

## ケース2: PCを失った場合

### 状況

- PCの故障・盗難・紛失
- OSの再インストールが必要になった
- 開発者が交代し、新PCで開発を始める

### 影響範囲

| 影響 | 内容 |
|---|---|
| コード | GitHubに最新版が存在する（本番と同期しているはず） |
| .env.local | ローカルにのみ存在するため消滅（ただし内容は軽微） |
| ローカル画像 | .gitignoreに含まれないPNG等はGitHubにある |
| 旧TSXファイル | .gitignoreに含まれているため消滅（参照用のみ・影響なし） |

### 復旧手順

**Step 1: 新PCに必要なツールをインストール**

```bash
# Python3（ローカルサーバー用）
python3 --version   # macOS標準でインストール済みのはず

# Git
git --version       # macOS標準またはXcode CLTでインストール済み
```

Node.js・npm・ビルドツールは不要。

**Step 2: GitHubからコードをクローン**

```bash
cd ~/Documents
git clone https://github.com/saimura-markan/hacchu-kanri-v2-.git hacchu-kanri
cd hacchu-kanri
```

**Step 3: .env.local を再作成**

```bash
# ~/Documents/hacchu-kanri/.env.local を作成
echo "FROM_EMAIL=noreply@markan.co.jp" > .env.local
```

> .env.local はEdge Function参照用のみ。ローカル動作に必須ではない。

**Step 4: ローカルサーバーで動作確認**

```bash
cd ~/Documents/hacchu-kanri
python3 -m http.server 8080
# ブラウザで http://localhost:8080 にアクセス
# Supabase接続（SUPABASE_URL・ANON_KEY）はindex.html内にハードコードされているため、接続は即座に復旧する
```

**Step 5: Claude Codeの設定確認**

```
# .claude/settings.local.json はGitignoreされているため再設定が必要
# Claude Code を hacchu-kanri ディレクトリで再起動するだけで再生成される
```

### 復旧所要時間の目安

**30〜60分**（Gitクローン・動作確認含む）

### 消滅するもの・消滅しないもの

| 項目 | 消滅 | 残存 |
|---|---|---|
| index.html（全コード） | | ✅ GitHub |
| SQLマイグレーションファイル（29本） | | ✅ GitHub |
| docs/ | | ✅ GitHub |
| README.md / CLAUDE.md | | ✅ GitHub |
| 画像ファイル（eli_img.png等） | | ✅ GitHub |
| edge-function-send-reset-email.ts | | ✅ GitHub |
| .env.local | ❌ ローカルのみ | |
| 旧TSXファイル（v3-*, v4-*） | ❌ .gitignore | |
| Supabaseデータ | | ✅ Supabaseサーバー |
| Storageの画像 | | ✅ Supabaseサーバー |
| Vercelデプロイ済み本番 | | ✅ Vercelサーバー |

---

## ケース3: Supabaseプロジェクトを失った場合

### 状況

- Supabaseプロジェクトが誤って削除された
- アカウントがロックされた
- Supabaseのサービス障害で長期間アクセス不能になった

### 影響範囲

これが最も深刻なケース。

| 影響 | 内容 |
|---|---|
| 認証 | ログインが完全に不可能になる |
| データ | 全発注データ・顧客データ・チャット・画像が消滅 |
| 本番稼働 | https://hacchu-kanri-v2.vercel.app が使用不能 |
| コード自体 | GitHubにあるため影響なし |

### 事前対策（平常時にやること）

定期的にデータをエクスポートすること（上述の「Supabaseバックアップ手順」参照）。

最低限、以下だけでも月次でダウンロードしておく：

```sql
-- 顧客・企業データ（最重要）
SELECT * FROM companies;
SELECT p.*, u.email FROM profiles p JOIN auth.users u ON p.id = u.id;

-- 発注データ
SELECT * FROM orders ORDER BY created_at DESC;
SELECT * FROM schedules;
SELECT * FROM cases;
```

### 復旧手順（新規Supabaseプロジェクトを作成する場合）

**Step 1: 新しいSupabaseプロジェクトを作成**

```
https://supabase.com → New Project
プロジェクト名: eli-hacchu-kanri（任意）
リージョン: Northeast Asia（Tokyo）
パスワード: 安全なものを設定・記録
```

**Step 2: 新しいURL・Anonキーを取得**

```
Supabase Dashboard → Settings → API
→ Project URL をコピー
→ anon public キーをコピー
```

**Step 3: index.html の接続情報を更新**

```js
// index.html 310〜311行目を新しい値に書き換える
const SUPABASE_URL      = '【新しいProject URL】';
const SUPABASE_ANON_KEY = '【新しいAnon Key】';
```

**Step 4: SQLスキーマを順番に適用**

以下の順番でSupabase SQL Editorに貼り付けて実行する。

```
# 順番が重要（依存関係あり）

1.  profiles_table.sql          ← profilesテーブル作成
2.  rls_policies.sql            ← 基本RLSポリシー
3.  order_images_table.sql      ← order_imagesテーブル
4.  add_deleted_at.sql          ← orders.deleted_at追加
5.  add_messages_index.sql      ← messagesインデックス
6.  add_company_is_active.sql   ← companies.is_active追加
7.  add_site_columns.sql        ← sitesカラム追加
8.  add_site_contact_columns.sql← 現場担当者カラム追加
9.  add_name_kana.sql           ← ふりがなカラム追加
10. add_orders_missing_columns.sql ← ordersカラム追加
11. add_reactions.sql           ← messagesリアクション追加
12. add_sender_id.sql           ← messages.sender_id追加
13. add_sender_name.sql         ← messages.sender_name追加
14. alter_messages_for_chat.sql ← チャット機能強化
15. add_schedule_history.sql    ← 日程変更履歴テーブル
16. add_site_history.sql        ← 現場情報変更履歴テーブル
17. add_staff_table.sql         ← staffテーブル作成
18. add_status_logs_table.sql   ← status_logsテーブル
19. add_order_change_logs.sql   ← 変更ログテーブル
20. add_cases_table.sql         ← casesテーブル・orders.case_id
21. rls_sites.sql               ← sitesテーブルRLS
22. drop_old_sites_policies.sql ← 旧sitesポリシー削除
23. storage_policies.sql        ← Storageポリシー
24. trigger_default_company_id.sql ← company_idトリガー
25. fix_null_company_id.sql     ← NULL company_id修正
26. fix_schedule_history_rls.sql← schedule_history RLS修正
27. fix_trigger_company_id.sql  ← トリガー修正
28. fix_cases_rls_insert.sql    ← cases INSERT RLS修正
29. fix_rls_policies_comprehensive.sql ← 包括的RLS修正（最後に実行）
```

> **注意:** `fix_rls_policies_comprehensive.sql` は他のすべてのSQL適用後に実行すること。内部にSTEP1（ロール移行SQL）とSTEP2（ポリシー適用）があり、コメントをよく読んでから実行する。

**Step 5: Storageバケットを再作成**

```
Supabase Dashboard → Storage → New Bucket
→ 「order-images」を作成（Public: OFF）
→ 「site-images」を作成（Public: OFF）
→ storage_policies.sql を再適用
```

**Step 6: Edge Functionを再デプロイ**

```
Supabase Dashboard → Edge Functions → New Function
関数名: send-reset-email
→ edge-function-send-reset-email.ts の内容を貼り付けてDeployする
```

Edge Function Secretsを設定：

```
Supabase Dashboard → Edge Functions → Manage secrets
→ RESEND_API_KEY = 【ResendダッシュボードのAPIキー】
→ SERVICE_ROLE_KEY = 【新しいSupabaseのサービスロールキー】
```

**Step 7: 管理者アカウントを再作成**

```
Supabase Dashboard → Authentication → Users → Invite
→ saimura@markan.co.jp
→ info@markan.co.jp
→ nakata@markan.co.jp
→ demo@markan.co.jp

# ロールをapp_metadataに設定（SQL Editor）
UPDATE auth.users
SET raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}'::jsonb
WHERE email IN ('saimura@markan.co.jp', 'info@markan.co.jp', 'nakata@markan.co.jp', 'demo@markan.co.jp');
```

**Step 8: バックアップデータを復元（データバックアップがある場合）**

```sql
-- CSVからのインポートは Supabase Dashboard → Table Editor → Import
-- または INSERT文に変換して SQL Editor で実行
```

**Step 9: index.htmlをコミット・デプロイして完了**

```bash
cd ~/Documents/hacchu-kanri
git add index.html
git commit -m "fix: update Supabase connection to new project"
git push origin main
# → Vercelが自動デプロイ → 本番復旧
```

### 復旧所要時間の目安

| 条件 | 目安 |
|---|---|
| コードのみ復旧（データなし） | 2〜4時間 |
| CSVバックアップからデータ復旧 | 4〜8時間 |
| データバックアップなしでゼロから | ほぼ不可能（過去発注データは消滅） |

---

## 復旧後の確認チェックリスト

復旧後、以下をすべて確認してから顧客への案内を再開すること。

```
[ ] ログイン画面が表示される
[ ] 管理者アカウントでログインできる
[ ] 一般ユーザーアカウントでログインできる（テストアカウントで確認）
[ ] 発注フォームが最後まで進み、Supabaseに保存される
[ ] 管理者画面で発注一覧が表示される
[ ] チャットが送受信できる
[ ] パスワードリセットメールが届く
[ ] 写真アップロードが機能する（order-images / site-images）
[ ] ステータス変更が保存される
[ ] 企業ID管理が動作する
[ ] スタッフ管理が動作する
```

---

## 平常時に備えること

| 対策 | 頻度 | 優先度 |
|---|---|---|
| 主要テーブルのCSVエクスポート | 月1回以上 | 最重要 |
| Storageの写真バックアップ | 月1回 | 重要 |
| GitHubにpushされているか確認 | 変更のたびに | 最重要 |
| Supabase接続情報をパスワードマネージャーに保存 | 即時 | 重要 |
| Resend APIキーをパスワードマネージャーに保存 | 即時 | 重要 |
| このドキュメント（disaster-recovery.md）を印刷して保管 | 即時 | 推奨 |

> **最重要:** Supabaseのサービスロールキーは絶対にGitHubにコミットしないこと。漏洩した場合は即座にSupabase Dashboard → Settings → API → Reset からキーを再生成すること。
