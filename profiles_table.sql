-- ================================================================
-- E-Li 工事受発注システム — profiles テーブル作成
-- ================================================================

CREATE TABLE profiles (
  id          uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name        text,
  phone       text,
  company     text,
  company_id  text,
  updated_at  timestamptz DEFAULT now()
);

-- updated_at を自動更新するトリガー
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- ----------------------------------------------------------------
-- RLS ポリシー
-- ----------------------------------------------------------------
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- ユーザー: 自分のプロフィールだけ読める
CREATE POLICY "users_read_own_profile"
  ON profiles FOR SELECT
  USING (id = auth.uid());

-- ユーザー: 自分のプロフィールを作成・更新できる
CREATE POLICY "users_upsert_own_profile"
  ON profiles FOR ALL
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- 管理者: 全プロフィールを読める
CREATE POLICY "admins_read_all_profiles"
  ON profiles FOR SELECT
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
