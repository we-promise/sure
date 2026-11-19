class AddEmailVerifiedAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :email_verified_at, :datetime, if_not_exists: true
    User.reset_column_information
    backfill!
  end

  def down
    remove_column :users, :email_verified_at, if_exists: true
  end

  # Existing accounts count as verified only when a trusted provider
  # (Google/Apple) proved the account's current email AND nobody else can
  # hold a password:
  #   - no password at all (Google/Apple-only sign-up), or
  #   - the password was set during the Google sign-up itself (identity
  #     created within a minute of the account, "backup password").
  # Password accounts that linked Google/Apple later stay unverified: the
  # password may belong to whoever registered the email first. So do accounts
  # whose email changed away from the address the provider proved.
  # The provider list is a snapshot of OidcIdentity::EMAIL_TRUSTED_PROVIDERS
  # at the time of this migration, so the backfill stays reproducible.
  # Public so the backfill can be tested against fixtures.
  def backfill!
    proven_emails = Hash.new { |hash, id| hash[id] = [] }
    select_rows(candidates_sql).each do |user_id, proven_email|
      proven_emails[user_id] << proven_email.to_s.strip if proven_email.present?
    end
    return if proven_emails.empty?

    # users.email is encrypted (deterministically) when encryption is
    # configured, so the comparison happens after the model decrypts it.
    verified_ids = User.where(id: proven_emails.keys).pluck(:id, :email).filter_map do |id, email|
      id if proven_emails[id].any? { |proven| proven.casecmp?(email.to_s.strip) }
    end

    verified_ids.each_slice(500) do |ids|
      execute(<<~SQL.squish)
        UPDATE users
        SET email_verified_at = COALESCE(users.created_at, CURRENT_TIMESTAMP)
        WHERE users.email_verified_at IS NULL
          AND users.id IN (#{ids.map { |id| connection.quote(id) }.join(", ")})
      SQL
    end
  end

  private

    def candidates_sql
      <<~SQL.squish
        SELECT users.id, oidc_identities.info ->> 'email'
        FROM users
        INNER JOIN oidc_identities ON oidc_identities.user_id = users.id
        WHERE users.email_verified_at IS NULL
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
      SQL
    end
end
