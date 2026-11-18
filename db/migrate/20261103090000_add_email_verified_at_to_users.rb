class AddEmailVerifiedAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :email_verified_at, :datetime, if_not_exists: true
    execute backfill_sql
  end

  def down
    remove_column :users, :email_verified_at, if_exists: true
  end

  # Existing accounts count as verified only when a trusted provider
  # (Google/Apple) proved the email AND nobody else can hold a password:
  #   - no password at all (Google/Apple-only sign-up), or
  #   - the password was set during the Google sign-up itself (identity
  #     created within a minute of the account, "backup password").
  # Password accounts that linked Google/Apple later stay unverified: the
  # password may belong to whoever registered the email first.
  # Public so the backfill can be tested against fixtures.
  def backfill_sql
    <<~SQL.squish
      UPDATE users
      SET email_verified_at = COALESCE(users.created_at, CURRENT_TIMESTAMP)
      WHERE users.email_verified_at IS NULL
        AND EXISTS (
          SELECT 1
          FROM oidc_identities
          WHERE oidc_identities.user_id = users.id
            AND (
              oidc_identities.provider IN ('google_oauth2', 'apple')
              OR (
                oidc_identities.provider = 'openid_connect'
                AND oidc_identities.issuer IN ('https://accounts.google.com', 'accounts.google.com')
              )
            )
            AND (
              users.password_digest IS NULL
              OR oidc_identities.created_at <= users.created_at + INTERVAL '60 seconds'
            )
        )
    SQL
  end
end
