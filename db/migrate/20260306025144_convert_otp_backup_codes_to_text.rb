class ConvertOtpBackupCodesToText < ActiveRecord::Migration[7.2]
  # DEPLOYMENT ORDER: This migration MUST run before enabling AR encryption
  # for otp_backup_codes. The raw SQL below operates on a plaintext PostgreSQL
  # array column and will fail or corrupt data if the column is already encrypted.
  def up
    add_column :users, :otp_backup_codes_text, :text

    execute <<~SQL
      UPDATE users
      SET otp_backup_codes_text = array_to_json(otp_backup_codes)::text
      WHERE otp_backup_codes IS NOT NULL
        AND array_length(otp_backup_codes, 1) > 0
    SQL

    remove_column :users, :otp_backup_codes
    rename_column :users, :otp_backup_codes_text, :otp_backup_codes
  end

  def down
    add_column :users, :otp_backup_codes_array, :string, array: true, default: []

    # Read through ActiveRecord to handle both encrypted and plaintext values.
    # Raw SQL can't decrypt AR-encrypted payloads.
    User.reset_column_information
    User.find_each do |user|
      codes = begin
        value = user.otp_backup_codes
        case value
        when Array then value
        when String then JSON.parse(value)
        else []
        end
      rescue JSON::ParserError, ActiveRecord::Encryption::Errors::Decryption => e
        Rails.logger.warn("[Migration] Could not restore backup codes for user #{user.id}: #{e.class} - #{e.message}")
        []
      end

      next if codes.empty?

      user.update_column(:otp_backup_codes_array, codes)
    end

    remove_column :users, :otp_backup_codes
    rename_column :users, :otp_backup_codes_array, :otp_backup_codes
  end
end
