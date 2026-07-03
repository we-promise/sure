# frozen_string_literal: true

class WiseItem::Importer
  include SyncStats::Collector

  HISTORY_DAYS = 365
  MINIMUM_HISTORY_FOR_INCREMENTAL = 10

  attr_reader :wise_item, :wise_provider, :sync

  def initialize(wise_item, wise_provider:, sync: nil)
    @wise_item     = wise_item
    @wise_provider = wise_provider
    @sync          = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "WiseItem::Importer - Starting import for item #{wise_item.id}"

    unless wise_item.wise_credentials
      raise CredentialsError, "No Wise credentials configured for item #{wise_item.id}"
    end

    # Fetch all profiles (personal + business) and sync balances from each
    profiles = fetch_profiles
    stats["profiles_found"] = profiles.size

    upstream_account_ids = []

    profiles.each do |profile|
      profile_id = profile[:id].to_s
      import_balances_for_profile(profile_id, upstream_account_ids)
    end

    prune_removed_accounts(upstream_account_ids)

    # For each linked account, fetch transaction history
    wise_item.linked_wise_accounts.each do |wise_account|
      import_transactions(wise_account)
    end

    wise_item.upsert_wise_snapshot!(stats)
  rescue Provider::Wise::AuthenticationError => e
    wise_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def register_error(type:, message:, context: {})
      entry = { type: type, message: message }.merge(context)
      stats["errors"] ||= []
      stats["errors"] << entry
    end

    def fetch_profiles
      response = wise_provider.list_profiles
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      Array(response)
    end

    def import_balances_for_profile(profile_id, upstream_account_ids)
      balances = begin
        response = wise_provider.list_balances(profile_id: profile_id)
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
        Array(response)
      rescue Provider::Wise::AuthenticationError
        raise
      rescue => e
        register_error(type: "profile_balances_error", message: e.message, context: { profile_id: profile_id })
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "error",
          message: "WiseItem::Importer - Failed to fetch balances for profile #{profile_id}: #{e.message}",
          source: "WiseItem::Importer",
          provider_key: "wise"
        )
        return
      end

      balances.each do |balance|
        safe_id = balance.is_a?(Hash) ? (balance[:id] || balance["id"]).to_s : nil
        begin
          balance = balance.with_indifferent_access if balance.is_a?(Hash)
          balance_id = balance[:id].to_s
          next if balance_id.blank?

          upsert_wise_account(profile_id, balance)
          upstream_account_ids << balance_id
          stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
        rescue => e
          register_error(type: "account_import_error", message: e.message, context: { balance_id: safe_id })
          DebugLogEntry.capture(
            category: "provider_sync",
            level: "error",
            message: "WiseItem::Importer - Failed to import balance #{safe_id}: #{e.message}",
            source: "WiseItem::Importer",
            provider_key: "wise"
          )
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        end
      end
    end

    def upsert_wise_account(profile_id, balance)
      balance_id = balance[:id].to_s
      amount_data = (balance[:amount] || {}).with_indifferent_access
      currency = (balance[:currency] || amount_data[:currency]).to_s.upcase

      wise_account = wise_item.wise_accounts.find_or_initialize_by(wise_account_id: balance_id)
      wise_account.assign_attributes(
        wise_profile_id:    profile_id,
        name:               balance[:name].presence || "#{currency} balance",
        currency:           currency,
        current_balance:    amount_data[:value].to_d,
        account_type:       balance[:type] || "STANDARD",
        institution_metadata: { name: "Wise", domain: "wise.com" },
        raw_payload:        balance
      )
      wise_account.save!
    end

    def import_transactions(wise_account)
      start_date = calculate_start_date(wise_account)
      end_date   = Date.current

      response = wise_provider.get_statement(
        profile_id: wise_account.wise_profile_id,
        balance_id: wise_account.wise_account_id,
        currency:   wise_account.currency,
        start_date: start_date,
        end_date:   end_date
      )
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      transactions = Array(response.is_a?(Hash) ? response[:transactions] : response)

      if transactions.any?
        merged = merge_transactions(wise_account.raw_transactions_payload || [], transactions)
        wise_account.update!(
          raw_transactions_payload: merged,
          last_transactions_sync: Time.current
        )
        stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions.size
      else
        wise_account.update!(last_transactions_sync: Time.current)
      end
    rescue Provider::Wise::AuthenticationError
      raise
    rescue => e
      register_error(type: "transaction_import_error", message: e.message, context: { wise_account_id: wise_account.id })
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "WiseItem::Importer - Failed to fetch transactions for wise_account #{wise_account.id}: #{e.message}",
        source: "WiseItem::Importer",
        provider_key: "wise"
      )
    end

    def calculate_start_date(wise_account)
      return wise_account.sync_start_date if wise_account.sync_start_date.present?

      existing_count = (wise_account.raw_transactions_payload || []).size
      if existing_count >= MINIMUM_HISTORY_FOR_INCREMENTAL && wise_account.last_transactions_sync.present?
        (wise_account.last_transactions_sync - 30.days).to_date
      else
        HISTORY_DAYS.days.ago.to_date
      end
    end

    def merge_transactions(existing, new_transactions)
      by_ref = {}
      existing.each  { |t| by_ref[transaction_key(t)] = t }
      new_transactions.each { |t| by_ref[transaction_key(t)] = t }
      by_ref.values
    end

    # Wise's referenceNumber is unique per transaction. Fall back to a
    # content hash for older entries that may lack it.
    def transaction_key(txn)
      txn = txn.with_indifferent_access if txn.is_a?(Hash)
      ref = txn[:referenceNumber]
      return ref if ref.present?

      desc = txn.dig(:details, :description).to_s
      [ txn[:date], txn[:type], txn.dig(:amount, :value), txn.dig(:amount, :currency), desc ].join("-")
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      removed = wise_item.wise_accounts.where.not(wise_account_id: upstream_account_ids)
      if removed.any?
        Rails.logger.info "WiseItem::Importer - Pruning #{removed.count} removed accounts"
        removed.destroy_all
      end
    end
end
