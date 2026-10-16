# frozen_string_literal: true

# API keys used to be stored as the secret itself in `display_key` (encrypted
# when ActiveRecord encryption is configured, plaintext otherwise), so anyone
# who could read the database could use every key. Keys are now stored as a
# one-way SHA-256 digest plus a short, non-secret prefix for display.
#
# This is step one of two. It adds the digest columns and backfills them from
# the existing keys, so every key keeps working. `display_key` is left in place
# (now nullable, and no longer written or read by the app) so a rollback keeps
# working; a follow-up release drops it.
class AddKeyDigestToApiKeys < ActiveRecord::Migration[8.1]
  KEY_PREFIX_LENGTH = 8

  # Reads the legacy column, decrypting it when the install encrypts it.
  class LegacyApiKey < ApplicationRecord
    self.table_name = "api_keys"
    include Encryptable

    if encryption_ready?
      encrypts :display_key, deterministic: true
    end
  end

  def up
    add_column :api_keys, :key_digest, :string
    add_column :api_keys, :key_prefix, :string
    change_column_null :api_keys, :display_key, true

    LegacyApiKey.reset_column_information

    say_with_time "Backfilling api_keys.key_digest from display_key" do
      skipped = 0

      LegacyApiKey.where(key_digest: nil).find_each do |api_key|
        plain_key = api_key.display_key

        if plain_key.blank?
          skipped += 1
          next
        end

        api_key.update_columns(
          key_digest: OpenSSL::Digest::SHA256.hexdigest(plain_key),
          key_prefix: plain_key.first(KEY_PREFIX_LENGTH)
        )
      rescue ActiveRecord::Encryption::Errors::Base => e
        # The key can't be read (e.g. encryption keys were rotated), so it
        # could never authenticate. Leave it without a digest.
        skipped += 1
        say "Could not read api_keys.id=#{api_key.id}: #{e.class}", true
      end

      say "Skipped #{skipped} key(s) that could not be read", true if skipped.positive?
      LegacyApiKey.where.not(key_digest: nil).count
    end

    add_index :api_keys, :key_digest, unique: true
  end

  def down
    remove_index :api_keys, :key_digest
    remove_column :api_keys, :key_prefix
    remove_column :api_keys, :key_digest

    LegacyApiKey.reset_column_information

    # For any keys created while the new code was running (which have no display_key),
    # mark them as revoked and populate display_key through LegacyApiKey so:
    # 1. Restoring the NOT NULL constraint succeeds without deleting user records.
    # 2. They cannot be guessed/authenticated on installs without encryption.
    # 3. On installs with encryption, the placeholder is properly encrypted so
    #    loading these rows post-rollback does not raise Decryption errors.
    LegacyApiKey.where(display_key: nil).find_each do |api_key|
      api_key.update!(
        display_key: SecureRandom.hex(32),
        revoked_at: api_key.revoked_at || Time.current
      )
    end

    change_column_null :api_keys, :display_key, false
  end
end
