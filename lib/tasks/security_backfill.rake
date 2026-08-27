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
    results[:akahu_items] = backfill_model(AkahuItem, %i[app_token user_token raw_payload raw_institution_payload], batch_size, dry_run)
    results[:binance_items] = backfill_model(BinanceItem, %i[api_key api_secret raw_payload], batch_size, dry_run)
    results[:brex_items] = backfill_model(BrexItem, %i[token raw_payload raw_institution_payload], batch_size, dry_run)
    results[:coinbase_items] = backfill_model(CoinbaseItem, %i[api_key api_secret raw_payload raw_institution_payload], batch_size, dry_run)
    results[:coinstats_items] = backfill_model(CoinstatsItem, %i[api_key raw_payload raw_institution_payload], batch_size, dry_run)
    results[:ibkr_items] = backfill_model(IbkrItem, %i[query_id token raw_payload], batch_size, dry_run)
    results[:indexa_capital_items] = backfill_model(IndexaCapitalItem, %i[password api_token username document raw_payload raw_institution_payload], batch_size, dry_run)
    results[:kraken_items] = backfill_model(KrakenItem, %i[api_key api_secret raw_payload], batch_size, dry_run)
    results[:mercury_items] = backfill_model(MercuryItem, %i[token raw_payload raw_institution_payload], batch_size, dry_run)
    results[:onchain_wallet_items] = backfill_model(OnchainWalletItem, %i[etherscan_api_key], batch_size, dry_run)
    results[:questrade_items] = backfill_model(QuestradeItem, %i[refresh_token raw_payload raw_institution_payload], batch_size, dry_run)
    results[:redbark_items] = backfill_model(RedbarkItem, %i[api_key raw_payload raw_institution_payload], batch_size, dry_run)
    results[:snaptrade_items] = backfill_model(SnaptradeItem, %i[client_id consumer_key snaptrade_user_secret oauth_access_token oauth_refresh_token raw_payload raw_institution_payload], batch_size, dry_run)
    results[:sophtron_items] = backfill_model(SophtronItem, %i[user_id access_key raw_payload raw_institution_payload raw_customer_payload raw_job_payload], batch_size, dry_run)
    results[:trading212_items] = backfill_model(Trading212Item, %i[api_key api_secret raw_instruments_payload], batch_size, dry_run)
    results[:up_items] = backfill_model(UpItem, %i[access_token raw_payload raw_institution_payload], batch_size, dry_run)
    results[:wise_items] = backfill_model(WiseItem, %i[token raw_payload], batch_size, dry_run)

    # Provider accounts
    results[:plaid_accounts] = backfill_model(PlaidAccount, %i[raw_payload raw_transactions_payload raw_holdings_payload raw_liabilities_payload], batch_size, dry_run)
    results[:simplefin_accounts] = backfill_model(SimplefinAccount, %i[raw_payload raw_transactions_payload raw_holdings_payload], batch_size, dry_run)
    results[:lunchflow_accounts] = backfill_model(LunchflowAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:enable_banking_accounts] = backfill_model(EnableBankingAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:snaptrade_accounts] = backfill_model(SnaptradeAccount, %i[raw_payload raw_transactions_payload raw_holdings_payload raw_activities_payload], batch_size, dry_run)
    results[:coinbase_accounts] = backfill_model(CoinbaseAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:coinstats_accounts] = backfill_model(CoinstatsAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:mercury_accounts] = backfill_model(MercuryAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:akahu_accounts] = backfill_model(AkahuAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:binance_accounts] = backfill_model(BinanceAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:brex_accounts] = backfill_model(BrexAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:ibkr_accounts] = backfill_model(IbkrAccount, %i[raw_holdings_payload raw_activities_payload raw_cash_report_payload raw_equity_summary_payload], batch_size, dry_run)
    results[:indexa_capital_accounts] = backfill_model(IndexaCapitalAccount, %i[raw_payload raw_holdings_payload raw_activities_payload], batch_size, dry_run)
    results[:kraken_accounts] = backfill_model(KrakenAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:onchain_wallet_accounts] = backfill_model(OnchainWalletAccount, %i[raw_payload raw_movements_payload], batch_size, dry_run)
    results[:questrade_accounts] = backfill_model(QuestradeAccount, %i[raw_payload raw_holdings_payload raw_activities_payload raw_balances_payload], batch_size, dry_run)
    results[:redbark_accounts] = backfill_model(RedbarkAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:sophtron_accounts] = backfill_model(SophtronAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:trading212_accounts] = backfill_model(Trading212Account, %i[raw_positions_payload raw_orders_payload raw_dividends_payload raw_transactions_payload], batch_size, dry_run)
    results[:up_accounts] = backfill_model(UpAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)
    results[:wise_accounts] = backfill_model(WiseAccount, %i[raw_payload raw_transactions_payload], batch_size, dry_run)

    # Sure's own first-party secrets
    results[:api_keys] = backfill_model(ApiKey, %i[display_key], batch_size, dry_run)
    results[:sso_providers] = backfill_model(SsoProvider, %i[client_secret], batch_size, dry_run)
    results[:sso_identity_blocks] = backfill_model(SsoIdentityBlock, %i[identity_label], batch_size, dry_run)

    # Only mark the backfill complete on a clean, non-dry-run pass: a partial
    # failure leaves some rows still plaintext, and flipping the flag would
    # disable the legacy-plaintext fallback (config/initializers/
    # active_record_encryption.rb) for models that still need it, turning a
    # readable row into a boot-time ActiveRecord::Encryption::Errors::Decryption.
    if !dry_run && results.values.all? { |r| r[:failed_count].zero? }
      Setting.encryption_backfill_completed_version = ActiveRecordEncryptionConfig::CURRENT_BACKFILL_VERSION
    end

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
