# frozen_string_literal: true

class PromotePlaidSecretsToDeclaredSettings < ActiveRecord::Migration[8.1]
  class MigrationSetting < ActiveRecord::Base
    self.table_name = "settings"
    self.filter_attributes += [ :value ]
    serialize :value, coder: YAML
  end

  class ConversionError < StandardError; end

  def up
    MigrationSetting.transaction(requires_new: true) do
      %w[plaid_secret plaid_eu_secret].each do |key|
        source = MigrationSetting.lock.find_by(var: "dynamic:#{key}")
        next unless source

        if MigrationSetting.exists?(var: key)
          raise ConversionError, "Both legacy and declared #{key} settings exist; resolve the conflict before upgrading"
        end

        plaintext = source.value
        unless plaintext.nil? || plaintext.is_a?(String)
          raise ConversionError, "Legacy #{key} is not a plaintext string; conversion requires operator review"
        end

        # Match the declared settings format without depending on future Setting accessors.
        ciphertext = plaintext.blank? ? plaintext : encryptor.encrypt_and_sign(plaintext)
        write = proc { source.update!(var: key, value: ciphertext) }
        MigrationSetting.logger ? MigrationSetting.logger.silence(&write) : write.call
      end

      Setting.clear_cache
    end
  rescue ConversionError
    raise
  rescue StandardError => error
    raise ConversionError, "Plaid secret conversion failed (#{error.class}); original settings were preserved", cause: nil
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Do not restore provider secrets to plaintext; restore a protected pre-upgrade backup instead"
  end

  private

    def encryptor
      @encryptor ||= begin
        secret_key_base = Rails.application.secret_key_base
        raise ConversionError, "SECRET_KEY_BASE is required to convert Plaid secrets" if secret_key_base.blank?

        key = ActiveSupport::KeyGenerator.new(secret_key_base).generate_key("setting_encryption", 32)
        ActiveSupport::MessageEncryptor.new(key)
      end
    end
end
