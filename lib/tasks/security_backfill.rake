# frozen_string_literal: true

namespace :security do
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

    results = {}
    puts "Starting security backfill (dry_run: #{dry_run}, batch_size: #{batch_size})..."

    # User fields (MFA + PII)
    # Note: otp_backup_codes excluded - it's a PostgreSQL array column incompatible with AR encryption
    results[:users] = backfill_model(User, %i[otp_secret email unconfirmed_email first_name last_name], batch_size, dry_run)

    # Invitation tokens and email
    results[:invitations] = backfill_model(Invitation, %i[token email], batch_size, dry_run)

    # InviteCode tokens
    results[:invite_codes] = backfill_model(InviteCode, %i[token], batch_size, dry_run)

    # Session user_agent (encryption) and ip_address_digest (hashing)
    results[:sessions] = backfill_sessions(batch_size, dry_run)

    # MobileDevice device_id
    results[:mobile_devices] = backfill_model(MobileDevice, %i[device_id], batch_size, dry_run)

    # Provider items
    results[:plaid_items] = backfill_model(PlaidItem, %i[access_token raw_payload raw_institution_payload], batch_size, dry_run)
    results[:simplefin_items] = backfill_model(SimplefinItem, %i[access_url raw_payload raw_institution_payload], batch_size, dry_run)
    results[:lunchflow_items] = backfill_model(LunchflowItem, %i[api_key raw_payload raw_institution_payload], batch_size, dry_run)
    results[:enable_banking_items] = backfill_model(EnableBankingItem, %i[client_certificate session_id raw_payload raw_institution_payload], batch_size, dry_run)

    # Provider accounts
    results[:plaid_accounts] = backfill_model(PlaidAccount, %i[raw_payload raw_transactions_payload raw_investments_payload raw_liabilities_payload], batch_size, dry_run)
    results[:simplefin_accounts] = backfill_model(SimplefinAccount, %i[raw_payload raw_transactions_payload raw_holdings_payload], batch_size, dry_run)
    results[:lunchflow_accounts] = backfill_model(LunchflowAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:enable_banking_accounts] = backfill_model(EnableBankingAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)

    puts({
      ok: true,
      dry_run: dry_run,
      batch_size: batch_size,
      results: results
    }.to_json)
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

        # Check if any field has data
        next unless fields.any? { |f| record.send(f).present? }

        next if dry_run

        begin
          # Touch fields to trigger re-encryption
          attrs = fields.each_with_object({}) do |field, hash|
            value = record.send(field)
            hash[field] = value if value.present?
          end

          record.update!(attrs) if attrs.present?
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

          # Re-save user_agent to trigger encryption
          changes[:user_agent] = session.user_agent if session.user_agent.present?

          # Hash IP address into ip_address_digest if not already done
          if session.ip_address.present? && session.ip_address_digest.blank?
            changes[:ip_address_digest] = Digest::SHA256.hexdigest(session.ip_address.to_s)
          end

          if changes.present?
            session.update!(changes)
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
