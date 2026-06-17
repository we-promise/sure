class UpItem::Importer
  attr_reader :up_item, :up_provider

  def initialize(up_item, up_provider:)
    @up_item = up_item
    @up_provider = up_provider
  end

  def import
    Rails.logger.info "UpItem::Importer - Starting import for item #{up_item.id}"

    accounts_data = fetch_accounts_data
    return failed_result("Failed to fetch accounts data") unless accounts_data

    up_item.upsert_up_snapshot!(accounts_data)

    account_stats = import_accounts(accounts_data)
    transaction_stats = import_transactions

    Rails.logger.info(
      "UpItem::Importer - Completed import for item #{up_item.id}: " \
      "#{account_stats[:updated]} accounts updated, #{account_stats[:created]} new accounts discovered, " \
      "#{transaction_stats[:imported]} transactions"
    )

    {
      success: account_stats[:failed].zero? && transaction_stats[:failed].zero?,
      accounts_updated: account_stats[:updated],
      accounts_created: account_stats[:created],
      accounts_failed: account_stats[:failed],
      transactions_imported: transaction_stats[:imported],
      transactions_failed: transaction_stats[:failed]
    }
  end

  private

    def fetch_accounts_data
      items = up_provider.get_accounts
      { items: items }
    rescue Provider::Up::UpError => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "UpItem::Importer - Up API error: #{e.error_type}"
      nil
    rescue JSON::ParserError => e
      Rails.logger.error "UpItem::Importer - Failed to parse Up API response: #{e.class}"
      nil
    rescue => e
      Rails.logger.error "UpItem::Importer - Unexpected error fetching accounts: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      nil
    end

    def import_accounts(accounts_data)
      stats = { updated: 0, created: 0, failed: 0 }
      accounts = Array(accounts_data[:items])
      linked_account_ids = up_item.up_accounts.joins(:account_provider).pluck(:account_id).map(&:to_s)
      all_existing_ids = up_item.up_accounts.pluck(:account_id).map(&:to_s)

      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank?
        next if account[:displayName].blank?

        if linked_account_ids.include?(account_id.to_s)
          import_account(account)
          stats[:updated] += 1
        elsif !all_existing_ids.include?(account_id.to_s)
          up_account = up_item.up_accounts.build(account_id: account_id.to_s)
          up_account.upsert_up_snapshot!(account)
          stats[:created] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "UpItem::Importer - Failed to import account #{account_id}: #{e.message}"
      end

      stats
    end

    def import_account(account_data)
      account = account_data.with_indifferent_access
      up_account = up_item.up_accounts.find_by(account_id: account[:id].to_s)
      return unless up_account

      up_account.upsert_up_snapshot!(account)
    end

    def import_transactions
      stats = { imported: 0, failed: 0 }

      up_item.up_accounts.joins(:account).merge(Account.visible).each do |up_account|
        result = fetch_and_store_transactions(up_account)
        if result[:success]
          stats[:imported] += result[:transactions_count]
        else
          stats[:failed] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "UpItem::Importer - Failed to fetch/store transactions for Up account #{up_account.id}: #{e.class}"
      end

      stats
    end

    def fetch_and_store_transactions(up_account)
      start_date = determine_sync_start_date(up_account)
      Rails.logger.info "UpItem::Importer - Fetching transactions for Up account #{up_account.id} since #{start_date}"

      transactions = up_provider.get_account_transactions(
        account_id: up_account.account_id,
        since: start_date
      )

      if Rails.configuration.x.up.debug_raw
        Rails.logger.debug "Up raw transactions response: #{transactions.to_json}"
      end

      store_transactions(up_account, fresh_transactions: Array(transactions))

      { success: true, transactions_count: Array(transactions).count }
    rescue Provider::Up::UpError => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "UpItem::Importer - Up API error for account #{up_account.id}: #{e.error_type}"
      { success: false, transactions_count: 0, error: I18n.t("up_item.errors.transactions_failed") }
    rescue JSON::ParserError => e
      Rails.logger.error "UpItem::Importer - Failed to parse transaction response for account #{up_account.id}: #{e.class}"
      { success: false, transactions_count: 0, error: "Failed to parse response" }
    rescue => e
      Rails.logger.error "UpItem::Importer - Unexpected error fetching transactions for account #{up_account.id}: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, transactions_count: 0, error: I18n.t("up_item.errors.transactions_failed") }
    end

    # Up returns both HELD (pending) and SETTLED transactions from the same endpoint.
    # Settled history accumulates; HELD transactions are only retained while they remain
    # present in the latest fetch, so cancelled/settled holds drop out of storage (and the
    # transactions processor prunes their stale pending entries).
    def store_transactions(up_account, fresh_transactions:)
      existing = up_account.raw_transactions_payload.to_a
      existing_settled = existing.reject { |tx| UpEntry::Processor.pending?(tx) }

      by_id = {}
      existing_settled.each do |tx|
        key = transaction_id(tx)
        by_id[key] = tx if key.present?
      end
      fresh_transactions.each do |tx|
        next unless tx.is_a?(Hash)

        key = transaction_id(tx)
        by_id[key] = tx if key.present?
      end

      final_transactions = by_id.values

      if final_transactions != existing
        Rails.logger.info(
          "UpItem::Importer - Storing #{final_transactions.count} transactions " \
          "(#{existing.count} existing) for account #{up_account.account_id}"
        )
        up_account.upsert_up_transactions_snapshot!(final_transactions)
      else
        Rails.logger.info "UpItem::Importer - No transaction changes for account #{up_account.account_id}"
      end
    end

    def transaction_id(transaction)
      data = transaction.with_indifferent_access
      data[:id].presence
    end

    def determine_sync_start_date(up_account)
      return up_account.sync_start_date if up_account.sync_start_date.present?
      return up_item.sync_start_date if up_item.sync_start_date.present?

      has_stored_transactions = up_account.raw_transactions_payload.to_a.any?
      if has_stored_transactions && up_item.last_synced_at
        up_item.last_synced_at - 7.days
      else
        90.days.ago
      end
    end

    def mark_requires_update!
      up_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "UpItem::Importer - Failed to update item status: #{e.message}"
    end

    def failed_result(error)
      { success: false, error: error, accounts_imported: 0, transactions_imported: 0 }
    end
end
