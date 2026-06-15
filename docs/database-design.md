# E-Li データベース設計

> 最終更新: 2026-06-15  
> ステータス凡例: ✅ 確認済み / ❌ 未実装 / ⚠️ 要確認  
> Supabase（PostgreSQL）を使用

---

## テーブル構成図

```
auth.users（Supabase Auth 管理）
  │
  ├─── profiles（ユーザープロフィール）
  │       └─── company_id → companies.id
  │
companies（企業）
  │
  ├─── sites（現場情報）
  │       └─── site_history（現場情報変更履歴）
  │
  └─── cases（案件）
          └─── orders（発注）
                  ├─── schedules（日程）
                  │       └─── schedule_history（日程変更履歴）
                  ├─── messages（チャット）
                  ├─── order_images（画像パス）
                  ├─── status_logs（ステータス変更ログ）
                  ├─── order_change_logs（現場情報変更ログ）
                  └─── site_history（現場情報変更履歴 ※order_idで紐づく）

staff（スタッフ情報）※ orders等との外部キーなし
```

---

## テーブル詳細

---

### companies（企業）

**用途:** 顧客企業の管理・企業IDの発行  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | text | 企業ID（例: MK-001）PRIMARY KEY |
| name | text | 企業名 |
| is_active | boolean | 有効/無効フラグ |
| created_at | timestamptz | 作成日時 |

**ポイント:**
- ログイン時に `is_active = false` なら弾く（実装済み）
- 管理者が CompanyPanel からCRUD操作

---

### profiles（ユーザープロフィール）

**用途:** auth.users と紐づくプロフィール情報  
**定義ファイル:** `profiles_table.sql`  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY（auth.users.id 参照） |
| name | text | 氏名（姓 + ' ' + 名） |
| name_kana | text | ふりがな（add_name_kana.sqlで追加） |
| phone | text | 電話番号 |
| company | text | 企業名（旧カラム・現在は companies テーブル参照） |
| company_id | text | 企業ID（companies.id 参照） |
| updated_at | timestamptz | 更新日時（トリガーで自動更新） |

**ポイント:**
- `company` カラムは旧来のもので、orders の insert 時には使用しない（2026-05-28修正済み）
- `company_id` が未設定の既存ユーザーがいる可能性あり ⚠️ 要確認

---

### sites（現場情報）

**用途:** 現場の住所・鍵・駐車場等を会社単位で管理  
**定義ファイル:** `add_site_columns.sql` 等  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| company_id | text | 企業ID（companies.id 参照） |
| site_name | text | 現場名 |
| address | text | 住所 |
| address_num | text | 番地 |
| address_bldg | text | 建物名 |
| zip_code | text | 郵便番号 |
| site_contact_name | text | 現場担当者名 |
| site_contact_phone | text | 現場担当者電話番号 |
| key_info | text | 鍵情報 |
| parking_info | text | 駐車場情報 |
| memo | text | メモ・注意事項 |
| images | text[] | 画像パス配列（site-imagesバケット） |
| created_at | timestamptz | 作成日時 |

**UNIQUE制約:** `(company_id, site_name)` ← upsertのonConflictキー

---

### site_history（現場情報変更履歴）

**用途:** お客様が現場情報を変更した際の記録  
**定義ファイル:** `add_site_history.sql`  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| order_id | text | 対象の発注ID |
| company_id | text | 企業ID |
| site_name | text | 現場名 |
| changed_by | uuid | 変更したユーザーID |
| field_name | text | 変更フィールド名 |
| field_label | text | 変更フィールドの表示名 |
| old_value | text | 変更前の値 |
| new_value | text | 変更後の値 |
| seen_by_admin | boolean | 管理者確認フラグ |
| changed_at | timestamptz | 変更日時 |

---

### cases（案件）

**用途:** companies → cases → orders の中間層  
**定義ファイル:** `add_cases_table.sql`  
**ステータス:** ✅ 確認済み（テーブル作成済み・フロントエンドでも使用中）

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| company_id | text | 企業ID（companies.id 参照） |
| site_id | uuid | 現場ID（sites.id 参照） |
| case_code | text | 案件番号（自動採番: KJ-001形式） UNIQUE |
| case_name | text | 案件名（現場名が入る） |
| created_at | timestamptz | 作成日時 |

**自動採番:** `fn_set_case_code()` トリガーで `KJ-{3桁ゼロ埋め}` を自動セット

**ポイント:**
- 1回の発注（複数サービス・複数日程）で1つの case を作成
- MK Connect連携時の案件番号として使う想定（将来）

---

### orders（発注）

**用途:** 各作業の発注情報  
**定義ファイル:** `add_orders_missing_columns.sql` 等  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | text | 発注ID（B-YYYY-NNN形式）PRIMARY KEY |
| user_id | uuid | 発注したユーザーID（auth.users参照） |
| company_id | text | 企業ID（companies.id 参照） |
| case_id | uuid | 案件ID（cases.id 参照） |
| service | text | サービス名（例: 養生・家具移動・荷上） |
| service_detail | jsonb | サービス詳細（フォーム全データ） |
| site | text | 現場名 |
| address | text | 住所 |
| key_info | text | 鍵情報 |
| parking | text | 駐車場情報 |
| note | text | 注意事項 |
| person | text | 担当者名 |
| person_kana | text | 担当者ふりがな |
| phone | text | 担当者電話番号 |
| site_contact_name | text | 現場担当者名 |
| site_contact_phone | text | 現場担当者電話番号 |
| status | text | ステータス（7段階） |
| status_changed_at | timestamptz | ステータス変更日時 |
| deleted_at | timestamptz | 論理削除日時（NULLで通常表示） |
| created_at | timestamptz | 作成日時 |

**ステータス値:**

| 値 | 色 | 意味 |
|---|---|---|
| `調整中` | 黄 | 受付直後 |
| `日程確定` | 青 | 日程が決定 |
| `日程相談中` | オレンジ | 日程を調整中 |
| `日程変更相談中` | 紫 | ユーザーが日程変更依頼 |
| `キャンセル相談中` | 薄赤 | ユーザーがキャンセル依頼 |
| `完了` | 緑 | 工事完了 |
| `キャンセル` | 赤 | キャンセル確定 |

---

### schedules（作業日程）

**用途:** orders に紐づく作業日程  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| order_id | text | 発注ID（orders.id 参照） |
| work_date | date | 作業日 |
| start_time | text | 開始時刻 |
| end_time | text | 終了時刻 |
| workers | text | 作業人数 |
| details | jsonb[] | 作業詳細配列 |
| sort_order | int | 表示順 |
| created_at | timestamptz | 作成日時 |

---

### schedule_history（日程変更履歴）

**用途:** 管理者が日程を変更した際の記録  
**定義ファイル:** `add_schedule_history.sql`  
**ステータス:** ✅ 確認済み（RLSポリシー適用は⚠️ 要確認）

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| schedule_id | uuid | 日程ID（schedules.id 参照） |
| old_date | date | 変更前の日付 |
| new_date | date | 変更後の日付 |
| old_start | text | 変更前の開始時刻 |
| new_start | text | 変更後の開始時刻 |
| old_end | text | 変更前の終了時刻 |
| new_end | text | 変更後の終了時刻 |
| changed_by | uuid | 変更したユーザーID |
| changed_at | timestamptz | 変更日時 |

---

### messages（チャット）

**用途:** 発注ごとのチャットメッセージ  
**定義ファイル:** `alter_messages_for_chat.sql`  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| order_id | text | 発注ID（orders.id 参照） |
| from_role | text | 送信者ロール（user / staff / eli） |
| sender_id | uuid | 送信者ユーザーID |
| sender_name | text | 送信者名 |
| text | text | メッセージ本文 |
| is_read | boolean | 既読フラグ（旧） |
| read_by | uuid[] | 既読ユーザーID配列 |
| reply_to_id | uuid | リプライ先メッセージID |
| mentions | text[] | メンション対象名配列 |
| reactions | jsonb | リアクション |
| created_at | timestamptz | 作成日時 |

---

### order_images（発注画像）

**用途:** 発注時の添付画像パス管理  
**定義ファイル:** `order_images_table.sql`  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| order_id | text | 発注ID（orders.id 参照） |
| path | text | Storageパス（例: {orderId}/0.jpg） |
| created_at | timestamptz | 作成日時 |

**Storageバケット:** `order-images`  
**パス形式:** `{orderId}/{連番}.jpg`（日本語・スペース禁止）

---

### status_logs（ステータス変更ログ）

**用途:** 誰がいつステータスを変更したかの記録  
**定義ファイル:** `add_status_logs_table.sql`  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| order_id | text | 発注ID |
| changed_by | uuid | 変更したユーザーID |
| old_status | text | 変更前ステータス |
| new_status | text | 変更後ステータス |
| changed_at | timestamptz | 変更日時 |

---

### order_change_logs（現場情報変更ログ）

**用途:** お客様が現場情報を変更した際の確認ログ  
**定義ファイル:** `add_order_change_logs.sql`  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| order_id | text | 発注ID |
| changed_by | uuid | 変更したユーザーID |
| field_name | text | 変更フィールド名 |
| old_value | text | 変更前の値 |
| new_value | text | 変更後の値 |
| confirmed_by | uuid | 確認した管理者ユーザーID |
| confirmed_at | timestamptz | 確認日時 |
| changed_at | timestamptz | 変更日時 |

---

### staff（スタッフ情報）

**用途:** 社内スタッフの管理  
**定義ファイル:** `add_staff_table.sql`  
**ステータス:** ✅ 確認済み

| カラム | 型 | 内容 |
|---|---|---|
| id | uuid | PRIMARY KEY |
| name | text | 氏名 |
| role | text | ロール（admin / manager / staff） |
| phone | text | 電話番号 |
| email | text | メールアドレス |
| is_active | boolean | 有効/無効フラグ |
| created_at | timestamptz | 作成日時 |

**ポイント:** auth.users とは独立したテーブル（外部キーなし）

---

## Storageバケット

| バケット名 | 用途 | ステータス |
|---|---|---|
| `order-images` | 発注時の添付写真 | ✅ 確認済み |
| `site-images` | 現場情報の写真・PDF | ✅ 確認済み |

---

## SQLマイグレーションファイル一覧

| ファイル名 | 内容 | 適用状況 |
|---|---|---|
| `profiles_table.sql` | profilesテーブル作成 | ⚠️ 要確認 |
| `rls_policies.sql` | 基本RLSポリシー | ⚠️ 要確認 |
| `rls_sites.sql` | sitesテーブルRLS | ⚠️ 要確認 |
| `storage_policies.sql` | Storageポリシー | ⚠️ 要確認 |
| `order_images_table.sql` | order_imagesテーブル | ⚠️ 要確認 |
| `add_deleted_at.sql` | orders.deleted_at追加 | ⚠️ 要確認 |
| `add_messages_index.sql` | messagesインデックス | ⚠️ 要確認 |
| `add_site_columns.sql` | sitesカラム追加 | ⚠️ 要確認 |
| `add_site_contact_columns.sql` | 現場担当者カラム追加 | ⚠️ 要確認 |
| `add_name_kana.sql` | name_kanaカラム追加 | ⚠️ 要確認 |
| `add_orders_missing_columns.sql` | ordersカラム追加 | ⚠️ 要確認 |
| `add_company_is_active.sql` | companies.is_active追加 | ⚠️ 要確認 |
| `add_reactions.sql` | messages.reactions追加 | ⚠️ 要確認 |
| `add_sender_id.sql` | messages.sender_id追加 | ⚠️ 要確認 |
| `add_sender_name.sql` | messages.sender_name追加 | ⚠️ 要確認 |
| `alter_messages_for_chat.sql` | messagesチャット機能強化 | ⚠️ 要確認 |
| `add_schedule_history.sql` | schedule_historyテーブル | ⚠️ 要確認 |
| `add_site_history.sql` | site_historyテーブル | ⚠️ 要確認 |
| `add_staff_table.sql` | staffテーブル作成 | ⚠️ 要確認 |
| `add_status_logs_table.sql` | status_logsテーブル | ⚠️ 要確認 |
| `add_order_change_logs.sql` | order_change_logsテーブル | ⚠️ 要確認 |
| `add_cases_table.sql` | casesテーブル・orders.case_id追加 | ⚠️ 要確認 |
| `drop_old_sites_policies.sql` | 旧sitesポリシー削除 | ⚠️ 要確認 |
| `fix_null_company_id.sql` | company_id NULLデータ修正 | ⚠️ 要確認 |
| `fix_trigger_company_id.sql` | company_idトリガー修正 | ⚠️ 要確認 |
| `fix_cases_rls_insert.sql` | casesテーブルINSERTポリシー修正 | ⚠️ 要確認 |
| `fix_schedule_history_rls.sql` | schedule_history RLS修正 | ⚠️ 要確認 |
| `fix_rls_policies_comprehensive.sql` | 包括的RLS修正（最新） | ⚠️ 要確認 |
| `trigger_default_company_id.sql` | company_idデフォルトトリガー | ⚠️ 要確認 |

> **注意:** 全SQLファイルはSupabase SQL Editorで手動実行が必要。自動マイグレーション管理（Supabase CLI 等）は使用していない。どのSQLが適用済みかを追跡する仕組みが現状ない。
