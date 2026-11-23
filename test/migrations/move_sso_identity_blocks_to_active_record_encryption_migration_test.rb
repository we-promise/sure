# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261117090000_move_sso_identity_blocks_to_active_record_encryption")

class MoveSsoIdentityBlocksToActiveRecordEncryptionMigrationTest < ActiveSupport::TestCase
  include SecretKeyBaseRotationHelper

  teardown { SsoIdentityBlock.reset_column_information }

  test "existing digest blocks keep matching after a SECRET_KEY_BASE change" do
    migrate(:down)
    insert_digest_block("legacy-subject")

    migrate(:up)

    assert SsoIdentityBlock.last.legacy_digest_key.present?
    with_rotated_secret_key_base do
      assert SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "legacy-subject")
    end
  end

  test "down keeps blocks stored with an encrypted subject identifier" do
    SsoIdentityBlock.create!(provider: "openid_connect", uid: "new-subject", identity_label: "removed-user@example.com")

    migrate(:down)

    assert_equal 1, connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT COUNT(*) FROM sso_identity_blocks WHERE uid_digest = ?", SsoIdentityBlock.digest("new-subject") ])
    )
    migrate(:up)
    assert SsoIdentityBlock.blocked?(provider: "openid_connect", uid: "new-subject")
  end

  test "down refuses to lift blocks after a SECRET_KEY_BASE change" do
    migrate(:down)
    insert_digest_block("legacy-subject")
    migrate(:up)

    with_rotated_secret_key_base do
      assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }
    end
  end

  test "down refuses a block whose subject identifier does not decrypt" do
    block = SsoIdentityBlock.create!(provider: "openid_connect", uid: "new-subject", identity_label: "removed-user@example.com")
    connection.execute(ActiveRecord::Base.sanitize_sql_array([ "UPDATE sso_identity_blocks SET uid = 'not-a-ciphertext' WHERE id = ?", block.id ]))

    assert_raises(ActiveRecord::IrreversibleMigration) { migrate(:down) }
  end

  test "down then up restores the columns and indexes" do
    before = shape

    migrate(:down)
    assert_not connection.column_exists?(:sso_identity_blocks, :uid)
    migrate(:up)

    assert_equal before, shape
  end

  private

    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { MoveSsoIdentityBlocksToActiveRecordEncryption.new.migrate(direction) }
      SsoIdentityBlock.reset_column_information
    end

    def insert_digest_block(uid)
      connection.execute(ActiveRecord::Base.sanitize_sql_array([ <<~SQL, SsoIdentityBlock.digest(uid) ]))
        INSERT INTO sso_identity_blocks (id, provider, uid_digest, identity_label, created_at, updated_at)
        VALUES (gen_random_uuid(), 'openid_connect', ?, 'Removed identity', NOW(), NOW())
      SQL
    end

    def shape
      [
        connection.columns(:sso_identity_blocks).map { |column| [ column.name, column.sql_type, column.null ] }.sort,
        connection.indexes(:sso_identity_blocks).map { |index| [ index.name, index.columns, index.unique, index.where ] }.sort
      ]
    end
end
