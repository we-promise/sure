# SimpleFin encryption backfill tasks
#
# Usage examples:
#   # Dry run (no writes), just prints how many would be processed
#   bin/rails sure:simplefin:encrypt_access_urls DRY_RUN=1
#
#   # Process all items in batches of 500
#   bin/rails sure:simplefin:encrypt_access_urls
#
#   # Limit to first 1000 items, batches of 200
#   bin/rails sure:simplefin:encrypt_access_urls LIMIT=1000 BATCH_SIZE=200
#
# Notes:
# - Do not log the actual access_url; treat it as a secret.
# - Safe to re-run; the operation is idempotent.
# - Uses Active Record Encryption configured in credentials; ensure
#   Rails.application.credentials.active_record_encryption is set in the environment.

namespace :sure do
  namespace :simplefin do
    desc "Backfill encryption for SimplefinItem.access_url (batched, idempotent)"
    task encrypt_access_urls: :environment do
      creds_present = Rails.application.credentials.active_record_encryption.present?
      env_present = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                    ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                    ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
      unless creds_present || env_present
        puts({ error: "active_record_encryption not configured via credentials or env; nothing to do" }.to_json)
        exit 2
      end

      # Allow reading legacy plaintext values during this backfill only
      Rails.application.config.active_record.encryption.support_unencrypted_data = true

      dry_run    = ENV["DRY_RUN"].to_s == "1"
      batch_size = (ENV["BATCH_SIZE"] || 500).to_i
      hard_limit = (ENV["LIMIT"] || 0).to_i

      scope = SimplefinItem.where.not(access_url: nil).order(:created_at)
      scope = scope.limit(hard_limit) if hard_limit > 0

      total = scope.count
      processed = 0
      updated = 0

      puts({ total_candidates: total, batch_size: batch_size, dry_run: dry_run }.to_json)

      if total == 0
        puts({ message: "No SimplefinItem rows with access_url present" }.to_json)
        next
      end

      scope.in_batches(of: batch_size) do |batch|
        ActiveRecord::Base.transaction do
          batch.each do |item|
            # Skip if access_url blank (scope filters nil already)
            # Read raw DB value to avoid decrypting legacy plaintext
            original = item.read_attribute_before_type_cast(:access_url)
            next if original.blank?

            if dry_run
              processed += 1
              next
            end

            # If value is already encrypted, skip; otherwise encrypt and write directly.
            already_encrypted = false
            begin
              # Try to decrypt the raw value; if it works, it's already encrypted
              ActiveRecord::Encryption.encryptor.decrypt(original)
              already_encrypted = true
            rescue StandardError
              already_encrypted = false
            end

            if already_encrypted
              processed += 1
              next
            end

            # Manually encrypt and write ciphertext to avoid decryption during change tracking
            ciphertext = ActiveRecord::Encryption.encryptor.encrypt(original)
            item.update_columns(access_url: ciphertext)
            updated += 1
            processed += 1
          end
        end
        puts({ processed: processed, updated: updated }.to_json)
      end

      puts({ done: true, processed: processed, updated: updated, total_candidates: total }.to_json)
    end
  end
end
