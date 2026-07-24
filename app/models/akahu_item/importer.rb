require "digest/md5"

class AkahuItem::Importer
  # Akahu's transactions endpoint only returns data from the requested `start`
  # onward (paginating the full range via cursor). On the first sync of an
  # account we therefore request a long lookback so all historic transactions
  # the connection can provide are pulled through, rather than clamping to a
  # short recent window. Akahu returns only the data that actually exists, so an
  # early start date simply captures everything available.
  INITIAL_SYNC_LOOKBACK = 5.years

  attr_reader :akahu_item, :akahu_provider

  def initialize(akahu_item, akahu_provider:)
    @akahu_item = akahu_item
    @akahu_provider = akahu_provider
  end

  def import
    Rails.logger.info "AkahuItem::Importer - Starting import for item #{akahu_item.id}"

    accounts_data = fetch_accounts_data
    return failed_result("Failed to fetch accounts data") unless accounts_data

    akahu_item.upsert_akahu_snapshot!(accounts_data)

    account_stats = import_accounts(accounts_data)
    pending_result = fetch_pending_transactions_by_account
    transaction_stats = import_transactions(pending_result)

    Rails.logger.info(
      "AkahuItem::Importer - Completed import for item #{akahu_item.id}: " \
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
      items = akahu_provider.get_accounts
      { items: items }
    rescue Provider::Akahu::AkahuError => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "AkahuItem::Importer - Akahu API error: #{e.error_type}"
      nil
    rescue JSON::ParserError => e
      Rails.logger.error "AkahuItem::Importer - Failed to parse Akahu API response: #{e.class}"
      nil
    rescue => e
      Rails.logger.error "AkahuItem::Importer - Unexpected error fetching accounts: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      nil
    end

    def import_accounts(accounts_data)
      stats = { updated: 0, created: 0, failed: 0 }
      accounts = Array(accounts_data[:items])
      linked_account_ids = akahu_item.akahu_accounts.joins(:account_provider).pluck(:account_id).map(&:to_s)
      all_existing_ids = akahu_item.akahu_accounts.pluck(:account_id).map(&:to_s)

      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:_id].presence || account[:id].presence
        next if account_id.blank?
        next if account[:name].blank?

        if linked_account_ids.include?(account_id.to_s)
          import_account(account)
          stats[:updated] += 1
        elsif !all_existing_ids.include?(account_id.to_s)
          akahu_account = akahu_item.akahu_accounts.build(account_id: account_id.to_s)
          akahu_account.upsert_akahu_snapshot!(account)
          stats[:created] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "AkahuItem::Importer - Failed to import account #{account_id}: #{e.message}"
      end

      stats
    end

    def import_account(account_data)
      account = account_data.with_indifferent_access
      account_id = account[:_id].presence || account[:id].presence
      akahu_account = akahu_item.akahu_accounts.find_by(account_id: account_id.to_s)
      return unless akahu_account

      akahu_account.upsert_akahu_snapshot!(account)
    end

    def fetch_pending_transactions_by_account
      pending_transactions = akahu_provider.get_pending_transactions

      by_account = pending_transactions.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |transaction, grouped|
        data = transaction.with_indifferent_access
        account_id = data[:_account].presence || data[:account].presence || data[:account_id].presence
        next if account_id.blank?

        grouped[account_id.to_s] << data.merge(_pending: true)
      end

      { success: true, by_account: by_account }
    rescue Provider::Akahu::AkahuError, JSON::ParserError, StandardError => e
      error_label = e.respond_to?(:error_type) ? e.error_type : e.class.name
      Rails.logger.warn "AkahuItem::Importer - Failed to fetch pending transactions: #{error_label}"
      { success: false, by_account: Hash.new { |hash, key| hash[key] = [] }, error: I18n.t("akahu_item.errors.pending_transactions_failed") }
    end

    def import_transactions(pending_result)
      stats = { imported: 0, failed: 0 }
      pending_by_account = pending_result[:by_account]
      pending_refresh_succeeded = pending_result[:success]

      akahu_item.akahu_accounts.joins(:account).merge(Account.visible).each do |akahu_account|
        result = fetch_and_store_transactions(
          akahu_account,
          pending_by_account[akahu_account.account_id.to_s],
          pending_refresh_succeeded: pending_refresh_succeeded
        )
        if result[:success]
          stats[:imported] += result[:transactions_count]
        else
          stats[:failed] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "AkahuItem::Importer - Failed to fetch/store transactions for Akahu account #{akahu_account.id}: #{e.class}"
      end

      stats
    end

    def fetch_and_store_transactions(akahu_account, pending_transactions, pending_refresh_succeeded:)
      start_date = determine_sync_start_date(akahu_account)
      Rails.logger.info "AkahuItem::Importer - Fetching transactions for Akahu account #{akahu_account.id} from #{start_date}"

      posted_transactions = akahu_provider.get_account_transactions(
        account_id: akahu_account.account_id,
        start_date: start_date
      )

      store_transactions(
        akahu_account,
        posted_transactions: Array(posted_transactions),
        pending_transactions: Array(pending_transactions),
        replace_pending: pending_refresh_succeeded
      )

      { success: true, transactions_count: Array(posted_transactions).count + Array(pending_transactions).count }
    rescue Provider::Akahu::AkahuError => e
      Rails.logger.error "AkahuItem::Importer - Akahu API error for account #{akahu_account.id}: #{e.error_type}"
      { success: false, transactions_count: 0, error: I18n.t("akahu_item.errors.transactions_failed") }
    rescue JSON::ParserError => e
      Rails.logger.error "AkahuItem::Importer - Failed to parse transaction response for account #{akahu_account.id}: #{e.class}"
      { success: false, transactions_count: 0, error: "Failed to parse response" }
    rescue => e
      Rails.logger.error "AkahuItem::Importer - Unexpected error fetching transactions for account #{akahu_account.id}: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, transactions_count: 0, error: I18n.t("akahu_item.errors.transactions_failed") }
    end

    def store_transactions(akahu_account, posted_transactions:, pending_transactions:, replace_pending:)
      existing_transactions = akahu_account.raw_transactions_payload.to_a
      existing_posted_transactions = existing_transactions.reject { |tx| pending_transaction?(tx) }
      existing_posted_keys = existing_posted_transactions.map { |tx| transaction_storage_key(tx.with_indifferent_access) }.compact.to_set
      seen_posted_keys = existing_posted_keys.dup

      new_posted_transactions = posted_transactions.select do |tx|
        next false unless tx.is_a?(Hash)

        key = transaction_storage_key(tx.with_indifferent_access)
        key.present? && seen_posted_keys.add?(key)
      end

      current_pending_keys = Set.new
      current_pending_transactions = pending_transactions.select do |tx|
        next false unless tx.is_a?(Hash)

        key = transaction_storage_key(tx.with_indifferent_access)
        next false if key.blank?

        key.start_with?("id:") ? current_pending_keys.add?(key) : true
      end

      final_transactions = if replace_pending
        existing_posted_transactions + new_posted_transactions + current_pending_transactions
      else
        existing_transactions + new_posted_transactions
      end

      if final_transactions != existing_transactions
        Rails.logger.info(
          "AkahuItem::Importer - Storing #{new_posted_transactions.count} new posted transactions " \
          "and #{current_pending_transactions.count} current pending transactions " \
          "(#{existing_transactions.count} existing) for account #{akahu_account.account_id}"
        )
        akahu_account.upsert_akahu_transactions_snapshot!(final_transactions)
      else
        Rails.logger.info "AkahuItem::Importer - No new transactions for account #{akahu_account.account_id}"
      end
    end

    def transaction_storage_key(transaction)
      id = transaction[:_id].presence || transaction[:id].presence
      return "id:#{id}" if id.present?

      attributes = [
        transaction[:_account],
        transaction[:account],
        transaction[:date],
        transaction[:amount],
        transaction[:description],
        transaction.dig(:merchant, :name),
        transaction[:type]
      ].compact.join("|")

      return nil if attributes.blank?

      "hash:#{Digest::MD5.hexdigest(attributes)}"
    end

    def pending_transaction?(transaction)
      data = transaction.with_indifferent_access
      ActiveModel::Type::Boolean.new.cast(data[:_pending]) == true ||
        ActiveModel::Type::Boolean.new.cast(data[:pending]) == true
    end

    def determine_sync_start_date(akahu_account)
      return akahu_account.sync_start_date if akahu_account.sync_start_date.present?
      return akahu_item.sync_start_date if akahu_item.sync_start_date.present?

      has_stored_transactions = akahu_account.raw_transactions_payload.to_a.any?
      if has_stored_transactions && akahu_item.last_synced_at
        akahu_item.last_synced_at - 7.days
      else
        INITIAL_SYNC_LOOKBACK.ago
      end
    end

    def mark_requires_update!
      akahu_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "AkahuItem::Importer - Failed to update item status: #{e.message}"
    end

    def failed_result(error)
      { success: false, error: error, accounts_imported: 0, transactions_imported: 0 }
    end
end
