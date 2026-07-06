class OpenBankingIoItem::Importer
  attr_reader :open_banking_io_item, :open_banking_io_provider

  def initialize(open_banking_io_item, open_banking_io_provider:)
    @open_banking_io_item = open_banking_io_item
    @open_banking_io_provider = open_banking_io_provider
  end

  def import
    Rails.logger.info "OpenBankingIoItem::Importer - Starting import for item #{open_banking_io_item.id}"

    accounts_data = fetch_accounts_data
    return failed_result("Failed to fetch accounts data") unless accounts_data

    open_banking_io_item.upsert_open_banking_io_snapshot!(accounts_data)

    account_stats = import_accounts(accounts_data)
    transaction_stats = import_transactions

    Rails.logger.info(
      "OpenBankingIoItem::Importer - Completed import for item #{open_banking_io_item.id}: " \
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
      items = open_banking_io_provider.get_accounts
      { items: items }
    rescue Provider::OpenBankingIo::Error => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "OpenBankingIoItem::Importer - open-banking.io API error: #{e.error_type}"
      nil
    rescue JSON::ParserError => e
      Rails.logger.error "OpenBankingIoItem::Importer - Failed to parse open-banking.io API response: #{e.class}"
      nil
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Unexpected error fetching accounts: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      nil
    end

    def import_accounts(accounts_data)
      stats = { updated: 0, created: 0, failed: 0 }
      accounts = Array(accounts_data[:items])
      linked_account_ids = open_banking_io_item.open_banking_io_accounts.joins(:account_provider).pluck(:account_id).map(&:to_s)
      all_existing_ids = open_banking_io_item.open_banking_io_accounts.pluck(:account_id).map(&:to_s)

      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank?

        if linked_account_ids.include?(account_id.to_s)
          import_account(account)
          stats[:updated] += 1
        elsif !all_existing_ids.include?(account_id.to_s)
          open_banking_io_account = open_banking_io_item.open_banking_io_accounts.build(account_id: account_id.to_s)
          open_banking_io_account.upsert_open_banking_io_snapshot!(account)
          stats[:created] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "OpenBankingIoItem::Importer - Failed to import account #{account_id}: #{e.message}"
      end

      stats
    end

    def import_account(account_data)
      account = account_data.with_indifferent_access
      account_id = account[:id].presence
      open_banking_io_account = open_banking_io_item.open_banking_io_accounts.find_by(account_id: account_id.to_s)
      return unless open_banking_io_account

      open_banking_io_account.upsert_open_banking_io_snapshot!(account)
    end

    def import_transactions
      stats = { imported: 0, failed: 0 }

      open_banking_io_item.open_banking_io_accounts.joins(:account).merge(Account.visible).each do |open_banking_io_account|
        result = fetch_and_store_transactions(open_banking_io_account)
        if result[:success]
          stats[:imported] += result[:transactions_count]
        else
          stats[:failed] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "OpenBankingIoItem::Importer - Failed to fetch/store transactions for account #{open_banking_io_account.id}: #{e.class}"
      end

      stats
    end

    def fetch_and_store_transactions(open_banking_io_account)
      start_date = determine_sync_start_date(open_banking_io_account)
      Rails.logger.info "OpenBankingIoItem::Importer - Fetching transactions for account #{open_banking_io_account.id} from #{start_date}"

      transactions = open_banking_io_provider.get_account_transactions(
        account_id: open_banking_io_account.account_id,
        start_date: start_date
      )

      store_transactions(open_banking_io_account, transactions: Array(transactions))

      { success: true, transactions_count: Array(transactions).count }
    rescue Provider::OpenBankingIo::Error => e
      Rails.logger.error "OpenBankingIoItem::Importer - open-banking.io API error for account #{open_banking_io_account.id}: #{e.error_type}"
      { success: false, transactions_count: 0, error: I18n.t("open_banking_io_item.errors.transactions_failed") }
    rescue JSON::ParserError => e
      Rails.logger.error "OpenBankingIoItem::Importer - Failed to parse transaction response for account #{open_banking_io_account.id}: #{e.class}"
      { success: false, transactions_count: 0, error: "Failed to parse response" }
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Unexpected error fetching transactions for account #{open_banking_io_account.id}: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, transactions_count: 0, error: I18n.t("open_banking_io_item.errors.transactions_failed") }
    end

    def store_transactions(open_banking_io_account, transactions:)
      existing_transactions = open_banking_io_account.raw_transactions_payload.to_a
      seen_keys = existing_transactions.filter_map { |tx| transaction_storage_key(tx) }.to_set

      new_transactions = transactions.select do |tx|
        next false unless tx.is_a?(Hash)

        key = transaction_storage_key(tx)
        key.present? && seen_keys.add?(key)
      end

      return if new_transactions.empty?

      final_transactions = existing_transactions + new_transactions
      Rails.logger.info(
        "OpenBankingIoItem::Importer - Storing #{new_transactions.count} new transactions " \
        "(#{existing_transactions.count} existing) for account #{open_banking_io_account.account_id}"
      )
      open_banking_io_account.upsert_open_banking_io_transactions_snapshot!(final_transactions)
    end

    def transaction_storage_key(transaction)
      data = transaction.with_indifferent_access
      id = data[:id].presence
      id.present? ? "id:#{id}" : nil
    end

    def determine_sync_start_date(open_banking_io_account)
      return open_banking_io_account.sync_start_date if open_banking_io_account.sync_start_date.present?
      return open_banking_io_item.sync_start_date if open_banking_io_item.sync_start_date.present?

      has_stored_transactions = open_banking_io_account.raw_transactions_payload.to_a.any?
      if has_stored_transactions && open_banking_io_item.last_synced_at
        open_banking_io_item.last_synced_at.to_date - 7.days
      else
        90.days.ago.to_date
      end
    end

    def mark_requires_update!
      open_banking_io_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Failed to update item status: #{e.message}"
    end

    def failed_result(error)
      { success: false, error: error, accounts_imported: 0, transactions_imported: 0 }
    end
end
