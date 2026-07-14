# frozen_string_literal: true

class WiseItem::Importer
  DEFAULT_HISTORY_DAYS = 90

  attr_reader :wise_item, :wise_provider, :sync_start_date

  def initialize(wise_item, wise_provider:, sync_start_date: nil)
    @wise_item = wise_item
    @wise_provider = wise_provider
    @sync_start_date = sync_start_date
  end

  def import
    Rails.logger.info "WiseItem::Importer - Starting import for item #{wise_item.id} (profile #{wise_item.profile_id})"

    balances = fetch_balances
    return failed_result("Failed to fetch balances") if balances.nil?

    savings_balances = fetch_savings_balances
    all_balances = Array(balances) + Array(savings_balances)

    borderless_accounts = fetch_borderless_accounts
    account_result = import_balances(all_balances, borderless_accounts: borderless_accounts)

    transfers = fetch_transfers
    activities = fetch_jar_activities
    transaction_result = store_transfers_per_account(transfers, activities: activities)
    @interbalance_activities = activities.select { |a| a["type"] == "INTERBALANCE" }

    wise_item.update!(status: :good) if account_result[:accounts_failed].zero? && transaction_result[:transactions_failed].zero?

    {
      success: account_result[:accounts_failed].zero? && transaction_result[:transactions_failed].zero?,
      **account_result,
      **transaction_result
    }
  end

  private

    def fetch_balances
      wise_provider.get_balances(wise_item.profile_id)
    rescue Provider::Wise::WiseError => e
      if e.error_type == :not_found
        Rails.logger.info "WiseItem::Importer - No balances for profile #{wise_item.profile_id}"
        return []
      end
      mark_requires_update_if_credentials_error(e)
      Rails.logger.error "WiseItem::Importer - Failed to fetch balances: #{e.message}"
      nil
    rescue => e
      Rails.logger.error "WiseItem::Importer - Unexpected error fetching balances: #{e.class} - #{e.message}"
      nil
    end

    def fetch_savings_balances
      wise_provider.get_savings_balances(wise_item.profile_id)
    rescue Provider::Wise::WiseError => e
      Rails.logger.info "WiseItem::Importer - No savings (JAR) balances for profile #{wise_item.profile_id}: #{e.message}"
      []
    rescue => e
      Rails.logger.warn "WiseItem::Importer - Unexpected error fetching savings balances: #{e.message}"
      []
    end

    # Returns a map of { balance_id => { borderless_account_id:, recipient_id: } }.
    # Used in WiseEntry::Processor to distinguish expenses (targetAccount != recipientId)
    # from incomes (targetAccount == recipientId).
    def fetch_borderless_accounts
      result = wise_provider.get_borderless_accounts(wise_item.profile_id)
      Array(result).each_with_object({}) do |ba, map|
        borderless_id = ba["id"]
        recipient_id  = ba["recipientId"]
        Array(ba["balances"]).each do |b|
          map[b["id"].to_s] = { borderless_account_id: borderless_id, recipient_id: recipient_id }
        end
      end
    rescue => e
      Rails.logger.warn "WiseItem::Importer - Could not fetch borderless accounts (#{e.message})"
      {}
    end

    def import_balances(balances, borderless_accounts: {})
      accounts_created = 0
      accounts_updated = 0
      accounts_failed = 0

      existing_ids = wise_item.wise_accounts.pluck(:balance_id).map(&:to_s).to_set

      Array(balances).each do |balance_data|
        data = balance_data.with_indifferent_access
        balance_id = data[:id].to_s
        currency = data.dig(:amount, :currency).to_s

        next if balance_id.blank? || currency.blank?

        account_ids = borderless_accounts[balance_id] || {}

        is_savings = data[:type] == "SAVINGS"
        api_name   = data[:name].presence

        wise_account = wise_item.wise_accounts.find_or_initialize_by(balance_id: balance_id)
        wise_account.currency ||= currency
        wise_account.name ||= api_name || (is_savings ? "Wise JAR #{currency}" : "Wise #{currency}")
        wise_account.upsert_wise_snapshot!(
          data,
          borderless_account_id: account_ids[:borderless_account_id],
          recipient_id: account_ids[:recipient_id]
        )

        if existing_ids.include?(balance_id)
          accounts_updated += 1
        else
          accounts_created += 1
          existing_ids << balance_id
        end
      rescue => e
        accounts_failed += 1
        Rails.logger.error "WiseItem::Importer - Failed to import balance #{balance_id.presence || 'unknown'}: #{e.message}"
      end

      { accounts_created: accounts_created, accounts_updated: accounts_updated, accounts_failed: accounts_failed }
    end

    # Fetches all profile activities and keeps only JAR-relevant types.
    def fetch_jar_activities
      cutoff = transfer_cutoff
      activities = []
      cursor = nil

      loop do
        result = with_rate_limit_retry { wise_provider.get_activities(wise_item.profile_id, cursor: cursor, size: 100) }
        batch = Array(result["activities"])
        break if batch.empty?

        old_ones = batch.select { |a| parse_transfer_date(a["createdOn"]) < cutoff }
        relevant = (batch - old_ones).select { |a| WiseActivity::Processor::JAR_ACTIVITY_TYPES.include?(a["type"]) }
        activities.concat(relevant)

        break if old_ones.any? || batch.size < 100

        cursor = result["cursor"]
        break if cursor.nil?
      end

      activities.uniq { |a| a["id"] }
    rescue Provider::Wise::WiseError => e
      Rails.logger.warn "WiseItem::Importer - Could not fetch activities (#{e.message})"
      []
    rescue => e
      Rails.logger.warn "WiseItem::Importer - Unexpected error fetching activities: #{e.message}"
      []
    end

    # Fetches all transfers for the profile, filtered to the sync window.
    def fetch_transfers
      cutoff = transfer_cutoff
      transfers = []
      offset = 0
      limit = 100

      loop do
        page = with_rate_limit_retry { wise_provider.get_transfers(wise_item.profile_id, limit: limit, offset: offset) }
        batch = Array(page.is_a?(Hash) ? page["content"] : page)
        break if batch.empty?

        # Wise returns transfers newest-first; stop once we're past the cutoff.
        old_ones = batch.select { |t| parse_transfer_date(t["created"]) < cutoff }
        transfers.concat(batch - old_ones)
        break if old_ones.any? || batch.size < limit

        offset += limit
      end

      transfers.uniq! { |t| t["id"] }
      Rails.logger.info "WiseItem::Importer - Fetched #{transfers.size} transfers for profile #{wise_item.profile_id}"
      transfers
    rescue Provider::Wise::WiseError => e
      Rails.logger.warn "WiseItem::Importer - Could not fetch transfers (#{e.message})"
      []
    rescue => e
      Rails.logger.warn "WiseItem::Importer - Unexpected error fetching transfers: #{e.message}"
      []
    end

    # Partitions transfers by the currency relevant to each WiseAccount:
    # - Expenses (outgoing): matched by sourceCurrency
    # - Incomes (incoming): matched by targetCurrency
    # Routes transfers to STANDARD accounts and activities to JAR accounts.
    def store_transfers_per_account(transfers, activities: [])
      transactions_imported = 0
      transactions_failed = 0

      wise_item.wise_accounts.find_each do |wise_account|
        if wise_account.jar?
          jar_activities = activities.select { |a| activity_for_account?(a, wise_account) }
          wise_account.upsert_wise_transactions_snapshot!(jar_activities)
          transactions_imported += jar_activities.size
        else
          account_transfers = transfers.select do |t|
            t["sourceCurrency"] == wise_account.currency ||
              t["targetCurrency"] == wise_account.currency
          end
          # Also include INTERBALANCE activities so the standard account shows outflows to the JAR.
          interbalance = activities.select { |a| activity_for_account?(a, wise_account) }
          wise_account.upsert_wise_transactions_snapshot!(account_transfers + interbalance)
          transactions_imported += account_transfers.size + interbalance.size
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "WiseItem::Importer - Failed to store transactions for wise_account #{wise_account.id}: #{e.message}"
      end

      { transactions_imported: transactions_imported, transactions_failed: transactions_failed }
    end

    # Routes an activity to the given WiseAccount.
    # JAR: receives INTERBALANCE where the activity title's <strong> tag matches the JAR name,
    #      plus BALANCE_CASHBACK and BALANCE_ASSET_FEE.
    # STANDARD: receives all INTERBALANCE activities (outflow side of JAR transfers).
    def activity_for_account?(activity, wise_account)
      type = activity["type"]

      case type
      when "INTERBALANCE"
        if wise_account.jar?
          jar_name_in_title = activity["title"].to_s.scan(/<strong>([^<]+)<\/strong>/).flatten.last.to_s.strip
          jar_name_in_title.present? && jar_name_in_title.casecmp?(wise_account.name.to_s.strip)
        else
          true
        end
      when "BALANCE_ASSET_FEE", "BALANCE_CASHBACK"
        wise_account.jar?
      else
        false
      end
    end

    # Called after entries have been created to link interbalance pairs as Sure Transfers.
    def link_interbalance_transfers!
      Array(@interbalance_activities).each do |activity|
        resource_id = activity.dig("resource", "id").to_s
        next if resource_id.blank?

        inflow_entry  = entry_by_external_id("wise_interbalance_#{resource_id}_inflow")
        outflow_entry = entry_by_external_id("wise_interbalance_#{resource_id}_outflow")

        next unless inflow_entry && outflow_entry

        inflow_txn  = inflow_entry.entryable
        outflow_txn = outflow_entry.entryable

        next unless inflow_txn.is_a?(Transaction) && outflow_txn.is_a?(Transaction)
        next if Transfer.exists?(inflow_transaction_id: inflow_txn.id)
        next if Transfer.exists?(outflow_transaction_id: outflow_txn.id)

        transfer = Transfer.new(
          inflow_transaction: inflow_txn,
          outflow_transaction: outflow_txn,
          status: "confirmed"
        )

        unless transfer.save
          Rails.logger.warn "WiseItem::Importer - Could not link interbalance #{resource_id}: #{transfer.errors.full_messages.join(", ")}"
        end
      rescue => e
        Rails.logger.error "WiseItem::Importer - Error linking interbalance #{resource_id}: #{e.message}"
      end
    end

    def entry_by_external_id(external_id)
      Entry.joins(account: :account_providers)
           .where(external_id: external_id, source: "wise")
           .where(account_providers: { provider_type: "WiseAccount" })
           .joins("INNER JOIN wise_accounts ON wise_accounts.id = account_providers.provider_id")
           .where(wise_accounts: { wise_item_id: wise_item.id })
           .first
    end

    def with_rate_limit_retry(max_retries: 3)
      retries = 0
      begin
        yield
      rescue Provider::Wise::WiseError => e
        raise unless e.error_type == :rate_limited && retries < max_retries
        retries += 1
        sleep(2 ** retries)
        retry
      end
    end

    def transfer_cutoff
      # Use last_synced_at only if we actually have stored transfers — otherwise fall back to full history.
      has_stored_transfers = wise_item.wise_accounts.any? { |wa| wa.raw_transactions_payload.present? }

      if has_stored_transfers && wise_item.last_synced_at.present?
        wise_item.last_synced_at - 7.days
      elsif sync_start_date.present?
        sync_start_date.to_time
      else
        DEFAULT_HISTORY_DAYS.days.ago
      end
    end

    def parse_transfer_date(raw)
      DateTime.parse(raw.to_s).to_time
    rescue
      Time.current
    end

    def mark_requires_update_if_credentials_error(error)
      return unless error.is_a?(Provider::Wise::WiseError) && error.error_type.in?([ :unauthorized, :access_forbidden ])

      wise_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "WiseItem::Importer - Failed to update item status: #{e.message}"
    end

    def failed_result(error)
      {
        success: false,
        error: error,
        accounts_created: 0,
        accounts_updated: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end
end
