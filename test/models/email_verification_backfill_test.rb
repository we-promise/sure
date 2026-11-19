require "test_helper"
require Rails.root.join("db/migrate/20261103090000_add_email_verified_at_to_users")

class EmailVerificationBackfillTest < ActiveSupport::TestCase
  setup do
    User.update_all(email_verified_at: nil)
  end

  test "trusted SSO-only accounts are verified" do
    google = account(password: nil, identity: { provider: "google_oauth2" })
    apple = account(password: nil, identity: { provider: "apple" })
    google_oidc = account(password: nil, identity: { provider: "openid_connect", issuer: "https://accounts.google.com" })

    run_backfill

    assert google.reload.email_verified?
    assert apple.reload.email_verified?
    assert google_oidc.reload.email_verified?
  end

  test "trusted SSO created alongside a backup password is verified" do
    user = account(password: "Password1!", identity: { provider: "google_oauth2", after: 5.seconds })

    run_backfill

    assert user.reload.email_verified?
  end

  test "password accounts linked to SSO later stay unverified" do
    user = account(password: "Password1!", identity: { provider: "google_oauth2", after: 2.days })

    run_backfill

    assert_not user.reload.email_verified?
  end

  test "password-only and untrusted-provider accounts stay unverified" do
    password_only = account(password: "Password1!")
    generic_oidc = account(password: nil, identity: { provider: "openid_connect", issuer: "https://idp.example.com" })

    run_backfill

    assert_not password_only.reload.email_verified?
    assert_not generic_oidc.reload.email_verified?
  end

  test "accounts whose email differs from the one the provider proved stay unverified" do
    changed = account(password: nil, identity: { provider: "google_oauth2", email: "old-address@example.com" })
    missing = account(password: nil, identity: { provider: "google_oauth2", email: nil })
    case_only = account(password: nil, identity: { provider: "google_oauth2" })
    case_only.oidc_identities.first.update_columns(info: { email: case_only.email.upcase })

    run_backfill

    assert_not changed.reload.email_verified?
    assert_not missing.reload.email_verified?
    assert case_only.reload.email_verified?
  end

  test "an account with a matching identity is verified even if another identity does not match" do
    user = account(password: nil, identity: { provider: "google_oauth2", email: "old-address@example.com" })
    OidcIdentity.create!(user: user, provider: "apple", uid: SecureRandom.hex(8), info: { email: user.email })

    run_backfill

    assert user.reload.email_verified?
  end

  private

    def run_backfill
      ActiveRecord::Migration.suppress_messages { AddEmailVerifiedAtToUsers.new.backfill! }
    end

    def account(password:, identity: nil)
      user = User.create!(
        email: "backfill-#{SecureRandom.hex(4)}@example.com",
        password: password,
        skip_password_validation: password.nil?,
        family: families(:empty)
      )
      user.update_columns(created_at: 3.days.ago, email_verified_at: nil)

      if identity
        record = OidcIdentity.create!(
          user: user,
          provider: identity[:provider],
          uid: SecureRandom.hex(8),
          issuer: identity[:issuer],
          info: { email: identity.fetch(:email, user.email) }
        )
        record.update_columns(created_at: user.created_at + identity.fetch(:after, 0.seconds))
      end

      user
    end
end
