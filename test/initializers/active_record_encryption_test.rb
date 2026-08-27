# frozen_string_literal: true

require "test_helper"

class ActiveRecordEncryptionInitializerTest < ActiveSupport::TestCase
  # Both settings are gated on ActiveRecordEncryptionConfig.backfill_completed?
  # (see #3214) instead of being unconditionally on. They're expected to be
  # `true` here because the initializer runs once at boot, before this test
  # (or any test) can flip Setting.encryption_backfill_completed_version -
  # the test suite always boots in the "backfill not completed" state.
  # Coverage for the gating logic itself (both the "complete" and
  # "not complete" branches) lives in test/lib/active_record_encryption_config_test.rb,
  # since re-running the initializer per-test isn't possible.
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
