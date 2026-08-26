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
end
