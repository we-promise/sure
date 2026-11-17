class MoveSsoIdentityBlocksToActiveRecordEncryption < ActiveRecord::Migration[8.1]
  # Salt of the HMAC key the existing uid digests were made with. That key is
  # derived from SECRET_KEY_BASE, so it is stored with each existing block
  # here: changing SECRET_KEY_BASE later must not lift the block.
  LEGACY_DIGEST_SALT = "sso_identity_block_uid"

  class MigrationBlock < ActiveRecord::Base
    self.table_name = "sso_identity_blocks"
  end

  def up
    add_column :sso_identity_blocks, :uid, :string
    add_column :sso_identity_blocks, :legacy_digest_key, :text
    change_column_null :sso_identity_blocks, :uid_digest, true
    add_index :sso_identity_blocks, [ :provider, :uid ], unique: true, where: "uid IS NOT NULL"

    return unless ActiveRecordEncryptionConfig.ready?

    block_model = encrypted_block_model
    key = Base64.strict_encode64(Rails.application.key_generator.generate_key(LEGACY_DIGEST_SALT, 32))
    block_model.where(legacy_digest_key: nil).where.not(uid_digest: nil).find_each do |block|
      block.legacy_digest_key = key
      block.save!(validate: false, touch: false)
    end
  end

  def down
    derived_key = Rails.application.key_generator.generate_key(LEGACY_DIGEST_SALT, 32)
    ensure_reversible!(derived_key)

    block_model = ActiveRecordEncryptionConfig.ready? ? encrypted_block_model : MigrationBlock
    begin
      block_model.where(uid_digest: nil).find_each do |block|
        block.update_columns(uid_digest: OpenSSL::HMAC.hexdigest("SHA256", derived_key, block.uid.to_s))
      end
    rescue ActiveRecord::Encryption::Errors::Base => e
      raise ActiveRecord::IrreversibleMigration,
        "An SSO identity block does not decrypt with the configured keys (#{e.class}); rolling back would lose it."
    end

    remove_index :sso_identity_blocks, [ :provider, :uid ]
    change_column_null :sso_identity_blocks, :uid_digest, false
    remove_column :sso_identity_blocks, :legacy_digest_key
    remove_column :sso_identity_blocks, :uid
  end

  private

    # The schema before this migration can only check digests made with the
    # current SECRET_KEY_BASE. Rolling back past a SECRET_KEY_BASE change, or
    # without the keys that decrypt the stored uids, would silently lift blocks.
    def ensure_reversible!(derived_key)
      return unless MigrationBlock.where.not(uid: nil).or(MigrationBlock.where.not(legacy_digest_key: nil)).exists?

      unless ActiveRecordEncryptionConfig.ready?
        raise ActiveRecord::IrreversibleMigration, "Active Record encryption keys are needed to roll back encrypted SSO identity blocks."
      end

      stored_keys = encrypted_block_model.where.not(legacy_digest_key: nil).pluck(:legacy_digest_key).uniq
      return if stored_keys.all? { |key| Base64.strict_decode64(key) == derived_key }

      raise ActiveRecord::IrreversibleMigration,
        "SECRET_KEY_BASE changed since this migration ran; rolling back would lift SSO identity blocks made before the change."
    rescue ActiveRecord::Encryption::Errors::Base => e
      raise ActiveRecord::IrreversibleMigration,
        "A stored SSO identity block key does not decrypt with the configured keys (#{e.class}); rolling back would lift blocks."
    end

    def encrypted_block_model
      MigrationBlock.reset_column_information
      Class.new(MigrationBlock) do
        def self.name = "SsoIdentityBlockMigrationRecord"
        # Strict reads: a value the keys do not decrypt must stop the
        # migration instead of being hashed or copied as if it were plaintext.
        encrypts :uid, deterministic: true, support_unencrypted_data: false
        encrypts :legacy_digest_key, support_unencrypted_data: false
      end
    end
end
