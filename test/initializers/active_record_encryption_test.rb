# frozen_string_literal: true

require "test_helper"

class ActiveRecordEncryptionInitializerTest < ActiveSupport::TestCase
  test "supports reading legacy plaintext data written before encryption was correctly gated" do
    # Without this, any not-yet-backfilled row (see bin/rails
    # security:backfill_encryption) raises ActiveRecord::Encryption::Errors::Decryption
    # the moment it's read, instead of falling back to the raw value.
    assert Rails.application.config.active_record.encryption.support_unencrypted_data
  end

  test "extends deterministic queries to also match legacy plaintext data" do
    # Without this, deterministic lookups (e.g. User.find_by(email:)) only
    # match already-encrypted rows and silently miss not-yet-backfilled ones.
    assert Rails.application.config.active_record.encryption.extend_queries
  end

  test "reads a legacy plaintext string value without raising" do
    skip "Encryption not configured" unless User.encryption_ready?

    user = users(:family_admin)
    # Bypass the encrypted setter to simulate a row written before encryption
    # was correctly gated (the exact bug fixed on this PR, see #3142).
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE users SET email = ? WHERE id = ?", "legacy-plaintext@example.com", user.id ])
    )

    assert_equal "legacy-plaintext@example.com", user.reload.email
  end

  test "deterministic find_by matches a legacy plaintext row for a plain (non-downcase) attribute" do
    skip "Encryption not configured" unless Invitation.encryption_ready?

    invitation = invitations(:one)
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE invitations SET token = ? WHERE id = ?", "legacy-token-abc", invitation.id ])
    )

    assert_equal invitation, Invitation.find_by(token: "legacy-token-abc")
  end

  # KNOWN LIMITATION (see the comment on extend_queries in
  # config/initializers/active_record_encryption.rb): deterministic finders
  # do not match legacy plaintext rows for attributes that combine
  # `encrypts ..., downcase: true` with a model-level `normalizes`
  # declaration - User#email is exactly that. This documents the current
  # behavior (returns nil, does not raise) so a future Rails upgrade that
  # fixes the underlying gap changes this test, not production behavior.
  test "deterministic find_by does not match a legacy plaintext row for a downcase+normalized attribute (known limitation)" do
    skip "Encryption not configured" unless User.encryption_ready?

    user = users(:family_admin)
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE users SET email = ? WHERE id = ?", "legacy-plaintext@example.com", user.id ])
    )

    assert_nil User.find_by(email: "legacy-plaintext@example.com")
    # The direct read still works (support_unencrypted_data) - only the
    # deterministic query match is affected.
    assert_equal "legacy-plaintext@example.com", user.reload.email
  end

  test "User.find_by_email works around the known limitation for legacy plaintext rows" do
    skip "Encryption not configured" unless User.encryption_ready?

    user = users(:family_admin)
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE users SET email = ? WHERE id = ?", "legacy-plaintext@example.com", user.id ])
    )

    assert_equal user, User.find_by_email("legacy-plaintext@example.com")
    # Also matches with surrounding whitespace/mixed case, like a raw form param.
    assert_equal user, User.find_by_email("  Legacy-Plaintext@Example.com  ")
  end

  test "User.authenticate_by_email works around the known limitation for legacy plaintext rows" do
    skip "Encryption not configured" unless User.encryption_ready?

    user = users(:family_admin)
    user.update!(password: "correct-horse-battery-staple")
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE users SET email = ? WHERE id = ?", "legacy-plaintext@example.com", user.id ])
    )

    assert_equal user, User.authenticate_by_email(email: "legacy-plaintext@example.com", password: "correct-horse-battery-staple")
    assert_nil User.authenticate_by_email(email: "legacy-plaintext@example.com", password: "wrong-password")
  end

  test "User.authenticate_by_email runs exactly one password check for an already-encrypted user" do
    skip "Encryption not configured" unless User.encryption_ready?

    user = users(:family_admin)
    user.update!(password: "correct-horse-battery-staple")

    BCrypt::Password.expects(:create).never
    BCrypt::Password.any_instance.expects(:is_password?).twice.returns(true, false)

    assert_equal user, User.authenticate_by_email(email: user.email, password: "correct-horse-battery-staple")
    assert_nil User.authenticate_by_email(email: user.email, password: "wrong-password")
  end

  test "User.authenticate_by_email still hashes the password for an SSO-only user" do
    skip "Encryption not configured" unless User.encryption_ready?

    user = users(:family_admin)
    user.update_column(:password_digest, nil)

    digest = BCrypt::Password.create("whatever", cost: BCrypt::Engine::MIN_COST)
    BCrypt::Password.expects(:create).once.returns(digest)

    assert_nil User.authenticate_by_email(email: user.email, password: "whatever")
  end

  test "User.authenticate_by_email rejects a blank or non-String password without raising" do
    skip "Encryption not configured" unless User.encryption_ready?

    user = users(:family_admin)

    BCrypt::Password.expects(:create).never
    assert_nil User.authenticate_by_email(email: user.email, password: "")
    assert_nil User.authenticate_by_email(email: user.email, password: nil)
    assert_nil User.authenticate_by_email(email: "no-such-user@example.com", password: "")

    BCrypt::Password.unstub(:create)
    assert_nil User.authenticate_by_email(email: user.email, password: 123456)
  end

  test "User.authenticate_by_email returns nil for an email that matches no user, plaintext or encrypted" do
    skip "Encryption not configured" unless User.encryption_ready?

    assert_nil User.authenticate_by_email(email: "no-such-user@example.com", password: "whatever")
  end

  test "User.authenticate_by_email still hashes the password for an email that matches no user" do
    skip "Encryption not configured" unless User.encryption_ready?

    # A miss must cost one bcrypt digest, like a hit, so response time does
    # not reveal whether an email is registered.
    digest = BCrypt::Password.create("whatever", cost: BCrypt::Engine::MIN_COST)
    BCrypt::Password.expects(:create).once.returns(digest)

    assert_nil User.authenticate_by_email(email: "no-such-user@example.com", password: "whatever")
  end

  test "email uniqueness also catches a legacy plaintext row" do
    skip "Encryption not configured" unless User.encryption_ready?

    # Unlike find_by(email:), the uniqueness validator's query is extended to
    # plaintext rows, so an SSO signup or email change cannot duplicate a
    # not-yet-backfilled user.

    user = users(:family_admin)
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE users SET email = ? WHERE id = ?", "legacy-plaintext@example.com", user.id ])
    )

    duplicate = User.new(email: "Legacy-Plaintext@example.com", family: Family.new, skip_password_validation: true)
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:email, :taken)

    # The legacy user itself can still be saved.
    user.reload.first_name = "Renamed"
    assert user.valid?, user.errors.full_messages.to_sentence
  end

  test "deterministic find_by matches a legacy plaintext row for downcase attributes without a model-level normalizes declaration" do
    skip "Encryption not configured" unless Invitation.encryption_ready? && InviteCode.encryption_ready?

    invitation = invitations(:one)
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE invitations SET email = ? WHERE id = ?", "legacy-invite@example.com", invitation.id ])
    )
    assert_equal invitation, Invitation.find_by(email: "legacy-invite@example.com")

    invite_code = InviteCode.create!
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE invite_codes SET token = ? WHERE id = ?", "legacy-token-xyz", invite_code.id ])
    )
    assert_equal invite_code, InviteCode.find_by(token: "legacy-token-xyz")
  end

  test "reads a legacy plaintext jsonb value as its original Hash, not a String" do
    skip "Encryption not configured" unless SnaptradeAccount.encryption_ready?

    account = snaptrade_accounts(:fidelity_401k)
    payload = { "account_category" => "DEPOSIT" }
    # jsonb columns need an explicit ::jsonb cast; a bare bind param would be
    # sent as text and rejected by the column type.
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql([ "UPDATE snaptrade_accounts SET raw_payload = ?::jsonb WHERE id = ?", payload.to_json, account.id ])
    )

    reloaded = account.reload.raw_payload
    assert_kind_of Hash, reloaded, "jsonb payload must deserialize to a Hash, not raw JSON text"
    assert_equal "DEPOSIT", reloaded["account_category"]
  end
end
