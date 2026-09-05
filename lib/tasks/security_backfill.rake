# frozen_string_literal: true

namespace :security do
  # Scope note: this task encrypts values that are still stored as PLAINTEXT.
  # It cannot detect or repair rows that were double-encoded by the pre-fix
  # version of this task (issue #2611): those decrypt "successfully" to a
  # JSON-text String on a json/jsonb column, which is indistinguishable here
  # from a legitimately stored string value, so mutating them automatically
  # would risk mangling valid data. If your instance ran the backfill before
  # the #2611 fix and provider payloads now decrypt to Strings (symptom:
  # zero balances on every provider-linked account after a sync), run the
  # manual recovery script in issue #2611 first, then re-run this task.
  desc "Backfill encryption for sensitive fields (idempotent). Args: batch_size, dry_run"
  task :backfill_encryption, [ :batch_size, :dry_run ] => :environment do |_, args|
    raw_batch = args[:batch_size].presence || ENV["BATCH_SIZE"].presence || "100"
    raw_dry = args[:dry_run].presence || ENV["DRY_RUN"].presence

    batch_size = raw_batch.to_i
    batch_size = 100 if batch_size <= 0

    dry_run = case raw_dry.to_s.strip.downcase
    when "0", "false", "no", "n" then false
    when "1", "true", "yes", "y" then true
    else
      true # Default to dry run for safety
    end

    # Check encryption configuration (use User model which includes Encryptable)
    unless User.encryption_ready?
      puts({
        ok: false,
        error: "encryption_not_configured",
        message: "ActiveRecord encryption is not configured. Set credentials or environment variables."
      }.to_json)
      exit 1
    end

    # Invalidate any previous completion flag before this run starts (not just
    # on failure at the end): if a prior run already completed successfully
    # and this run then fails or aborts partway through, leaving the old flag
    # in place would let ActiveRecordEncryptionConfig.backfill_completed?
    # report "complete" while this run's still-plaintext rows are unencrypted.
    Setting.encryption_backfill_completed_version = nil unless dry_run

    results = {}
    puts "Starting security backfill (dry_run: #{dry_run}, batch_size: #{batch_size})..."

    # Note: otp_backup_codes excluded from User's fields below - it's a
    # PostgreSQL array column incompatible with AR encryption.
    #
    # Field lists live in ActiveRecordEncryptionConfig::BACKFILL_MANIFEST
    # (lib/active_record_encryption_config.rb), the single source of truth
    # kept in sync with each model's `encrypts` declarations by
    # test/lib/tasks/security_backfill_test.rb - update the manifest, not
    # this loop, to add or change coverage.
    ActiveRecordEncryptionConfig::BACKFILL_MANIFEST.each do |key, (model_class_name, fields)|
      results[key] = backfill_model(model_class_name.constantize, fields, batch_size, dry_run)
    end

    # Session user_agent (encryption) and ip_address_digest (hashing) - not
    # part of BACKFILL_MANIFEST, see its comment for why.
    results[:sessions] = backfill_sessions(batch_size, dry_run)

    all_succeeded = results.values.all? { |r| r[:failed_count].zero? }

    # Only mark the backfill complete on a clean, non-dry-run pass: a partial
    # failure leaves some rows still plaintext, and flipping the flag would
    # disable the legacy-plaintext fallback (config/initializers/
    # active_record_encryption.rb) for models that still need it, turning a
    # readable row into a boot-time ActiveRecord::Encryption::Errors::Decryption.
    if !dry_run && all_succeeded
      Setting.encryption_backfill_completed_version = ActiveRecordEncryptionConfig::CURRENT_BACKFILL_VERSION
    end

    puts({
      ok: all_succeeded,
      dry_run: dry_run,
      batch_size: batch_size,
      results: results
    }.to_json)

    # An operator or deployment automation checking only the process exit
    # code must be able to tell a partial failure apart from real success -
    # ok: false in the JSON above isn't enough on its own since nothing
    # forces anyone to parse it.
    exit 1 unless all_succeeded
  end

  def backfill_model(model_class, fields, batch_size, dry_run, &filter_block)
    processed = 0
    updated = 0
    failed = []

    model_class.order(:id).in_batches(of: batch_size) do |batch|
      batch.each do |record|
        processed += 1

        # Skip if filter block returns false
        next if block_given? && !filter_block.call(record)

        # Check if any field has data (use safe read to handle plaintext).
        # Nil-check rather than present?: empty values ({}, [], "") are still
        # plaintext that needs encrypting — present? skips them, leaving data
        # the encrypted getters raise on once keys are live.
        next unless fields.any? { |f| !safe_read_field(record, f).nil? }

        next if dry_run

        begin
          # Read plaintext values safely
          plaintext_values = {}
          fields.each do |field|
            value = safe_read_field(record, field)
            plaintext_values[field] = value unless value.nil?
          end

          next if plaintext_values.empty?

          # Use a temporary instance to encrypt values (avoids triggering
          # validations/callbacks that might read other encrypted fields)
          encryptor = model_class.new
          plaintext_values.each do |field, value|
            encryptor.send("#{field}=", value)
          end

          # Extract the encrypted values from the temporary instance
          encrypted_attrs = {}
          plaintext_values.keys.each do |field|
            encrypted_attrs[field] = encryptor.read_attribute_before_type_cast(field)
          end

          # Write directly to database, bypassing callbacks/validations
          record.update_columns(encrypted_attrs)
          updated += 1
        rescue => e
          failed << { id: record.id, error: e.class.name, message: e.message }
        end
      end
    end

    {
      processed: processed,
      updated: updated,
      failed_count: failed.size,
      failed_samples: failed.take(3)
    }
  end

  # Safely read a field value, handling both encrypted and plaintext data.
  # When encryption is configured but the value is plaintext, the getter
  # raises ActiveRecord::Encryption::Errors::Decryption. In this case,
  # we fall back to reading the raw database value. For json/jsonb columns
  # the raw value is the JSON text, not the deserialized Array/Hash the
  # encrypted setter expects, so parse it first — otherwise the backfill
  # encrypts the JSON text itself and the column thereafter decrypts to a
  # String, breaking every consumer of the payload.
  def safe_read_field(record, field)
    record.send(field)
  rescue ActiveRecord::Encryption::Errors::Decryption
    raw = record.read_attribute_before_type_cast(field)
    column = record.class.columns_hash[field.to_s]
    if raw.is_a?(String) && [ :json, :jsonb ].include?(column&.type)
      begin
        JSON.parse(raw)
      rescue JSON::ParserError
        raw
      end
    else
      raw
    end
  end

  def backfill_sessions(batch_size, dry_run)
    processed = 0
    updated = 0
    failed = []

    Session.order(:id).in_batches(of: batch_size) do |batch|
      batch.each do |session|
        processed += 1
        next if dry_run

        begin
          changes = {}

          # Re-save user_agent to trigger encryption (use safe read for plaintext)
          user_agent_value = safe_read_field(session, :user_agent)
          unless user_agent_value.nil?
            # Use temporary instance to encrypt
            encryptor = Session.new
            encryptor.user_agent = user_agent_value
            changes[:user_agent] = encryptor.read_attribute_before_type_cast(:user_agent)
          end

          # Hash IP address into ip_address_digest if not already done
          if session.ip_address.present? && session.ip_address_digest.blank?
            changes[:ip_address_digest] = Digest::SHA256.hexdigest(session.ip_address.to_s)
          end

          if changes.present?
            session.update_columns(changes)
            updated += 1
          end
        rescue => e
          failed << { id: session.id, error: e.class.name, message: e.message }
        end
      end
    end

    {
      processed: processed,
      updated: updated,
      failed_count: failed.size,
      failed_samples: failed.take(3)
    }
  end
end
