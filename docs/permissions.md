# E-Li 権限設計

> 最終更新: 2026-06-15  
> ステータス凡例: ✅ 確認済み / ❌ 未実装 / ⚠️ 要確認

---

## ロール一覧

| ロール | 対象 | アクセス先 | 設定場所 |
|---|---|---|---|
| `user` | 一般顧客（デフォルト） | HistoryApp / OrderApp / MyPage | 未設定時は自動付与 |
| `staff` | 社内スタッフ（閲覧専用） | AdminApp（一部ボタン非表示） | Supabase Dashboard |
| `manager` | マネージャー | AdminApp（スタッフ管理以外） | Supabase Dashboard |
| `admin` | 管理者（全機能） | 全画面 | Supabase Dashboard |

---

## ロール設定方法

### 現在の方法（user_metadata）✅ 確認済み

```sql
-- Supabase Dashboard → Authentication → Users → Edit → user_metadata に設定
{ "role": "admin" }
```

### 推奨される方法（app_metadata）⚠️ 要確認

`fix_rls_policies_comprehensive.sql` にてapp_metadataへの移行が提案されている。

```sql
-- app_metadata への移行（STEP1: 既存ユーザーを一括移行）
UPDATE auth.users
SET raw_app_meta_data = raw_app_meta_data ||
      jsonb_build_object('role', raw_user_meta_data ->> 'role')
WHERE raw_user_meta_data ->> 'role' IS NOT NULL
  AND (raw_app_meta_data ->> 'role') IS NULL;

-- 今後の設定方法（app_metadata に直接）
UPDATE auth.users
SET raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}'::jsonb
WHERE email = 'xxx@markan.co.jp';
```

**理由:** `user_metadata` はユーザー自身が `supabase.auth.updateUser()` で書き換え可能なため、認可判定に使うと権限昇格のリスクがある。`app_metadata` はサービスロールキーでのみ書き込めるため安全。

---

## ⚠️ 重要：現在のロール判定不整合

| 箇所 | 参照先 | ステータス |
|---|---|---|
| フロントエンド（画面制御） | `user_metadata.role` | ✅ 動作しているが安全でない |
| RLSポリシー（fix_rls_policies_comprehensive.sql） | `app_metadata.role`（get_my_role()関数） | ⚠️ SQLファイルの適用状況不明 |
| RLSポリシー（rls_policies.sql 等 旧ファイル） | `user_metadata.role` または `app_metadata.role` | ⚠️ どちらが有効か要確認 |

**リスク:** app_metadataへの移行SQLが未適用の場合、ユーザーが自分でロールを書き換えて管理者権限を取得できる可能性がある。

---

## 画面別アクセス制御

| 画面 | user | staff | manager | admin |
|---|---|---|---|---|
| ログイン画面 | ✅ | ✅ | ✅ | ✅ |
| 新規登録 | ✅ | ✅ | ✅ | ✅ |
| 発注フォーム（OrderApp） | ✅ | ❌ | ❌ | ❌ |
| 注文履歴（HistoryApp） | ✅ | ❌ | ❌ | ❌ |
| マイページ | ✅ | ✅ | ✅ | ✅ |
| 管理者画面（AdminApp） | ❌ | ✅ | ✅ | ✅ |

---

## 管理者画面内の機能別制御

| 機能 | staff | manager | admin |
|---|---|---|---|
| 発注一覧の閲覧 | ✅ | ✅ | ✅ |
| 案件詳細の閲覧 | ✅ | ✅ | ✅ |
| チャット送受信 | ✅ | ✅ | ✅ |
| ProWon用コピー | ✅ | ✅ | ✅ |
| ステータス変更 | ❌ | ✅ | ✅ |
| 日程編集 | ❌ | ✅ | ✅ |
| 発注の論理削除 | ❌ | ✅ | ✅ |
| タイマー警告表示 | ❌ | ❌ | ✅ |
| 企業ID管理（🏢） | ❌ | ❌ | ✅ |
| スタッフ管理（👷） | ❌ | ✅ | ✅ |
| 削除済み案件（🗑️）| ❌ | ❌ | ✅ |

---

## RLS（Row Level Security）ポリシー

> RLSは Supabase（PostgreSQL）側でデータアクセスを制御する仕組み。  
> フロントエンドの表示制御とは独立して機能する。

### orders テーブル

| 操作 | 対象ロール | 内容 | ステータス |
|---|---|---|---|
| SELECT | user | 自分の orders のみ（user_id = auth.uid()） | ✅ 確認済み（コード上） |
| SELECT | admin / manager / staff | 全件 | ✅ 確認済み（コード上） |
| INSERT | user | 自分の orders のみ | ✅ 確認済み（コード上） |
| INSERT | admin / manager | 全件（電話受注等） | ✅ 確認済み（コード上） |
| UPDATE | admin / manager | 全件（ステータス変更等） | ✅ 確認済み（コード上） |
| DELETE | なし（論理削除） | deleted_at で対応 | ✅ 確認済み |

### profiles テーブル

| 操作 | 対象ロール | 内容 | ステータス |
|---|---|---|---|
| SELECT | user | 自分のプロフィールのみ | ✅ 確認済み（コード上） |
| SELECT | admin | 全件 | ✅ 確認済み（コード上） |
| ALL | user | 自分のプロフィールのみ（upsert） | ✅ 確認済み（コード上） |

### messages テーブル

| 操作 | 対象ロール | 内容 | ステータス |
|---|---|---|---|
| SELECT | user | 自分の order_id に紐づくもの | ✅ 確認済み（コード上） |
| SELECT | admin / manager / staff | 全件 | ✅ 確認済み（コード上） |
| INSERT | user / staff / eli | 送信可能 | ✅ 確認済み（コード上） |
| UPDATE | admin / manager / staff | 既読処理（read_by更新） | ✅ 確認済み（コード上） |

### cases テーブル

| 操作 | 対象ロール | 内容 | ステータス |
|---|---|---|---|
| ALL | admin / manager | 全件CRUD | ✅ 確認済み（コード上） |
| SELECT | staff | 全件 | ✅ 確認済み（コード上） |
| SELECT | user | 自社の案件のみ（company_idで絞り込み） | ✅ 確認済み（コード上） |

### order_change_logs テーブル

| 操作 | 対象ロール | 内容 | ステータス |
|---|---|---|---|
| INSERT | user | 自分が changed_by のレコードのみ | ✅ 確認済み（コード上） |
| SELECT | admin / manager / staff | 全件 | ✅ 確認済み（コード上） |
| UPDATE | admin / manager | confirmed_by のセット | ✅ 確認済み（コード上） |

> **注意:** 「コード上」とは `.sql` ファイルに定義が存在することを示す。Supabase側での実際の適用・有効化は ⚠️ 要確認。

---

## 管理者アカウント（本番）

| メールアドレス | ロール |
|---|---|
| saimura@markan.co.jp | admin |
| info@markan.co.jp | admin |
| nakata@markan.co.jp | admin |
| demo@markan.co.jp | admin |

---

## パスワードポリシー

| 条件 | 内容 | ステータス |
|---|---|---|
| 最低文字数 | 8文字以上 | ✅ 確認済み（フロントエンドバリデーション） |
| 文字種 | 英字・数字の両方を含む | ✅ 確認済み（フロントエンドバリデーション） |
| Supabase側ポリシー | 未確認 | ⚠️ 要確認 |

---

## 通知バッジ制御（管理者画面）

| バッジ | 表示条件 | 消去条件 | ステータス |
|---|---|---|---|
| 💬 未読チャット（赤） | user からの未読メッセージが1件以上 | チャットを既読にする | ✅ 確認済み |
| @ メンション（青） | 自分宛のメンションが未読 | チャットを既読にする | ✅ 確認済み |
| 📋 現場情報更新（橙） | seen_by_admin = false の site_history が1件以上 | 管理者が案件を開く | ✅ 確認済み |
| 📝 変更ログ未確認（橙） | confirmed_by = NULL の order_change_logs が1件以上 | 管理者が確認ボタンを押す | ✅ 確認済み |
