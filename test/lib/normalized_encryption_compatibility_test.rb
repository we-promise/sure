require "test_helper"
require "open3"
require "rbconfig"

class NormalizedEncryptionCompatibilityTest < ActiveSupport::TestCase
  # Use the real users table and Rails relation/validator, without changing User's
  # encryption declarations or global keys for other tests.
  class PreviousSchemeUser < ApplicationRecord
    self.table_name = "users"

    encrypts :email,
      deterministic: { fixed: false },
      support_unencrypted_data: false,
      key_provider: ActiveRecord::Encryption::KeyProvider.new(
        ActiveRecord::Encryption::Key.new("c" * 32)
      ),
      previous: [ {
        deterministic: true,
        support_unencrypted_data: false,
        key_provider: ActiveRecord::Encryption::KeyProvider.new(
          ActiveRecord::Encryption::Key.new("p" * 32)
        )
      } ]
    normalizes :email, with: ->(email) { email&.strip&.downcase }
    validates :email, uniqueness: true
  end

  test "normalized encrypted query regressions pass in a fresh process" do
    env = ENV.to_h.slice(
      "PATH", "GEM_HOME", "GEM_PATH", "BUNDLE_PATH", "BUNDLE_GEMFILE",
      "BUNDLE_DEPLOYMENT", "BUNDLE_WITHOUT"
    )
    output, status = Open3.capture2e(
      env, RbConfig.ruby, "-rbundler/setup",
      Rails.root.join("test/standalone/normalized_encryption_compatibility_check.rb").to_s,
      chdir: Rails.root.to_s, unsetenv_others: true
    )

    assert status.success?, output
    assert_match(/13 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/, output)
  end

  test "previous scheme ciphertext prevents a duplicate normalized email" do
    skip "requires encryption query extensions" unless User.encryption_ready? && ActiveRecord::Encryption.config.extend_queries

    existing = users(:family_admin)
    duplicate_attributes = existing.attributes.except("id", "created_at", "updated_at")
    email = "previous-scheme-user@example.test"
    type = PreviousSchemeUser.type_for_attribute("email")
    previous_ciphertext = type.previous_types.first.serialize(email)

    assert_not_equal email, previous_ciphertext
    assert_not_equal type.serialize(email), previous_ciphertext

    connection = PreviousSchemeUser.connection
    connection.execute(
      "UPDATE users SET email = #{connection.quote(previous_ciphertext)} WHERE id = #{connection.quote(existing.id)}"
    )
    assert_equal previous_ciphertext, connection.select_value(
      "SELECT email FROM users WHERE id = #{connection.quote(existing.id)}"
    )
    assert_equal email, PreviousSchemeUser.find(existing.id).email
    assert_equal existing.id, PreviousSchemeUser.find_by!(email: "  PREVIOUS-Scheme-User@EXAMPLE.TEST  ").id
    assert_equal [ existing.id ], PreviousSchemeUser.where(email: "  PREVIOUS-Scheme-User@EXAMPLE.TEST  ").pluck(:id)

    duplicate = PreviousSchemeUser.new(duplicate_attributes)
    duplicate.email = "  PREVIOUS-Scheme-User@EXAMPLE.TEST  "
    assert_no_difference "User.count" do
      assert_not duplicate.save
    end
    assert duplicate.errors.of_kind?(:email, :taken)
  end
end
