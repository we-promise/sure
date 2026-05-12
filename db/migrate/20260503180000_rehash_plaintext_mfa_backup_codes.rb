# frozen_string_literal: true

class RehashPlaintextMfaBackupCodes < ActiveRecord::Migration[7.2]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  BCRYPT_PREFIXES = %w[$2a$ $2b$ $2y$].freeze
  PLAINTEXT_BACKUP_CODE_PATTERN = /\A[0-9a-f]{8}\z/

  def up
    require "bcrypt"

    say_with_time "Rehashing plaintext MFA backup codes" do
      rehashed_users_count = 0

      MigrationUser.where(otp_required: true).find_each do |user|
        backup_codes = Array(user.otp_backup_codes)
        next if backup_codes.blank?
        next unless backup_codes.any? { |code| plaintext_backup_code?(code) }

        rehashed_codes = backup_codes.map do |code|
          plaintext_backup_code?(code) ? BCrypt::Password.create(normalize_backup_code(code), cost: bcrypt_cost).to_s : code
        end

        user.update_columns(otp_backup_codes: rehashed_codes, updated_at: Time.current)
        rehashed_users_count += 1
      end

      rehashed_users_count
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private
    def plaintext_backup_code?(code)
      normalized_code = normalize_backup_code(code)
      normalized_code.match?(PLAINTEXT_BACKUP_CODE_PATTERN) && BCRYPT_PREFIXES.none? { |prefix| normalized_code.start_with?(prefix) }
    end

    def normalize_backup_code(code)
      code.to_s.strip.downcase
    end

    def bcrypt_cost
      ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    end
end
