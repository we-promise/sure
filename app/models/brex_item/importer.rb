# frozen_string_literal: true

class BrexItem::Importer
  attr_reader :brex_item, :brex_provider, :sync_start_date

  def initialize(brex_item, brex_provider: nil, sync_start_date: nil)
    @brex_item = brex_item
    @brex_provider = brex_provider
    @sync_start_date = sync_start_date
    @provided_context = BrexItem::LegacyAccess.transport_context(brex_item) if brex_provider
  end

  def import
    BrexItem::LegacyAccess.with_item(brex_item) do |current|
      BrexItem::LegacyAccess.assert_transport!
      BrexItem::LegacyAccess.verify_transport!(current, @provided_context) if @provided_context
      @brex_item = current
      @transport_context = BrexItem::LegacyAccess.transport_context(current)
      @brex_provider ||= current.brex_provider
      raise Provider::Brex::BrexError.new("Brex provider is not configured", :not_configured) unless brex_provider
      if brex_provider.is_a?(Provider::Brex) && (brex_provider.token != current.token ||
          brex_provider.base_url != Provider::Brex.normalize_base_url(current.base_url))
        raise BrexItem::LegacyAccess::Fence::OwnershipChanged, "Brex client does not match the admitted credentials"
      end
      import_admitted
    end
  end

  private

    def import_admitted
      Rails.logger.info "BrexItem::Importer - Starting import for item #{brex_item.id}"

      accounts_data = fetch_accounts_data
      return failed_result("Failed to fetch accounts data") unless accounts_data

      store_item_snapshot(accounts_data)

      account_result = import_accounts(accounts_data[:accounts].to_a)
      transaction_result = import_transactions

      if account_result[:accounts_failed].zero? && transaction_result[:transactions_failed].zero?
        BrexItem::LegacyAccess.with_snapshot(brex_item, expected_context: @transport_context) { |fresh| fresh.update!(status: :good) }
      end

      {
        success: account_result[:accounts_failed].zero? && transaction_result[:transactions_failed].zero?,
        **account_result,
        **transaction_result
      }
    end

    def fetch_accounts_data
      verify_request!
      accounts_data = brex_provider.get_accounts

      unless accounts_data.is_a?(Hash) && accounts_data.with_indifferent_access[:accounts].is_a?(Array)
        Rails.logger.error "BrexItem::Importer - Invalid accounts_data format: expected Hash, got #{accounts_data.class}"
        return nil
      end

      accounts_data.with_indifferent_access
    rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue Provider::Brex::BrexError => e
      mark_requires_update_if_credentials_error(e)
      Rails.logger.error "BrexItem::Importer - Brex API error: #{e.message} trace_id=#{e.trace_id}"
      nil
    rescue JSON::ParserError => e
      Rails.logger.error "BrexItem::Importer - Failed to parse Brex API response: #{e.message}"
      nil
    rescue => e
      Rails.logger.error "BrexItem::Importer - Unexpected error fetching accounts: #{e.class} - #{e.message}"
      Rails.logger.error Array(e.backtrace).join("\n")
      nil
    end

    def store_item_snapshot(accounts_data)
      brex_item.upsert_brex_snapshot!(accounts_data, expected_context: @transport_context)
    rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue => e
      Rails.logger.error "BrexItem::Importer - Failed to store accounts snapshot: #{e.message}"
      Sentry.capture_exception(e) do |scope|
        scope.set_tags(brex_item_id: brex_item.id)
        scope.set_context("brex_item_snapshot", {
          brex_item_id: brex_item.id,
          accounts_data: BrexAccount.sanitize_payload(accounts_data)
        })
      end
      raise
    end

    def import_accounts(accounts)
      accounts_updated = 0
      accounts_created = 0
      accounts_failed = 0

      all_existing_ids = brex_item.brex_accounts.pluck("#{BrexAccount.table_name}.account_id").map(&:to_s)

      accounts.each do |account_data|
        snapshot = account_data.with_indifferent_access
        account_id = snapshot[:id].to_s
        account_name = BrexAccount.name_for(snapshot)
        next if account_id.blank? || account_name.blank?

        if all_existing_ids.include?(account_id)
          import_account(snapshot)
          accounts_updated += 1
        else
          import_account(snapshot)
          accounts_created += 1
          all_existing_ids << account_id
        end
      rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
        raise
      rescue => e
        accounts_failed += 1
        Rails.logger.error "BrexItem::Importer - Failed to import account #{account_id.presence || 'unknown'}: #{e.message}"
      end

      {
        accounts_updated: accounts_updated,
        accounts_created: accounts_created,
        accounts_failed: accounts_failed
      }
    end

    def import_account(account_data)
      account_id = account_data[:id].to_s
      raise ArgumentError, "Account ID is required" if account_id.blank?

      brex_account = brex_item.brex_accounts.find_or_initialize_by(account_id: account_id)
      brex_account.name ||= BrexAccount.name_for(account_data)
      brex_account.currency ||= BrexAccount.currency_code_from_money(account_data[:current_balance] || account_data[:available_balance] || account_data[:account_limit])
      brex_account.upsert_brex_snapshot!(account_data, expected_item_context: @transport_context)
      brex_account
    end

    def import_transactions
      transactions_imported = 0
      transactions_failed = 0

      brex_item.brex_accounts.joins(:account).merge(Account.visible).find_each do |brex_account|
        result = fetch_and_store_transactions(brex_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
        else
          transactions_failed += 1
        end
      rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
        raise
      rescue => e
        transactions_failed += 1
        Rails.logger.error "BrexItem::Importer - Failed to fetch/store transactions for account #{brex_account.account_id}: #{e.message}"
      end

      {
        transactions_imported: transactions_imported,
        transactions_failed: transactions_failed
      }
    end

    def fetch_and_store_transactions(brex_account)
      brex_account = BrexItem::LegacyAccess.with_account(brex_account, operation: :ingest) { |fresh| fresh }
      expected_context = BrexItem::LegacyAccess.source_context(brex_account)
      start_date = determine_sync_start_date(brex_account)
      Rails.logger.info "BrexItem::Importer - Fetching #{brex_account.account_kind} transactions for account #{brex_account.account_id} from #{start_date}"

      verify_request!
      transactions_data = if brex_account.card?
        brex_provider.get_primary_card_transactions(start_date: start_date)
      else
        brex_provider.get_cash_transactions(brex_account.account_id, start_date: start_date)
      end

      unless transactions_data.is_a?(Hash) && transactions_data.with_indifferent_access[:transactions].is_a?(Array)
        Rails.logger.error "BrexItem::Importer - Invalid transactions_data format for account #{brex_account.account_id}"
        return { success: false, transactions_count: 0, error: "Invalid response format" }
      end

      transactions = transactions_data.with_indifferent_access.fetch(:transactions)
      created_count = store_new_transactions(brex_account, transactions, window_start_date: start_date, expected_context: expected_context)

      { success: true, transactions_count: created_count }
    rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue Provider::Brex::BrexError => e
      mark_requires_update_if_credentials_error(e)
      Rails.logger.error "BrexItem::Importer - Brex API error for account #{brex_account.account_id}: #{e.message} trace_id=#{e.trace_id}"
      { success: false, transactions_count: 0, error: e.message }
    rescue JSON::ParserError => e
      Rails.logger.error "BrexItem::Importer - Failed to parse transaction response for account #{brex_account.account_id}: #{e.message}"
      { success: false, transactions_count: 0, error: "Failed to parse response" }
    rescue => e
      Rails.logger.error "BrexItem::Importer - Unexpected error fetching transactions for account #{brex_account.account_id}: #{e.class} - #{e.message}"
      Rails.logger.error Array(e.backtrace).join("\n")
      { success: false, transactions_count: 0, error: "Unexpected error: #{e.message}" }
    end

    def store_new_transactions(brex_account, transactions, window_start_date:, expected_context:)
      existing_payload = brex_account.raw_transactions_payload.to_a
      existing_transactions = transactions_in_window(existing_payload, window_start_date)
      existing_ids = existing_transactions.map { |tx| tx.with_indifferent_access[:id] }.to_set

      new_transactions = transactions.select do |tx|
        tx_id = tx.with_indifferent_access[:id]
        tx_id.present? && !existing_ids.include?(tx_id) && transaction_in_window?(tx, window_start_date)
      end

      BrexItem::LegacyAccess.with_source_snapshot(brex_account, expected_context: expected_context,
        expected_item_context: @transport_context) do |fresh|
        # Even a no-change response must prove it still belongs to this request.
        unless new_transactions.empty? && existing_transactions.count == existing_payload.count
          fresh.update!(raw_transactions_payload: BrexAccount.sanitize_payload(existing_transactions + new_transactions))
        end
      end
      new_transactions.count
    end

    def transactions_in_window(transactions, window_start_date)
      transactions.select { |transaction| transaction_in_window?(transaction, window_start_date) }
    end

    def transaction_in_window?(transaction, window_start_date)
      return true if window_start_date.blank?

      transaction_date = transaction_date_for(transaction)
      return true if transaction_date.blank?

      transaction_date >= window_start_date.to_date
    end

    def transaction_date_for(transaction)
      data = transaction.with_indifferent_access
      date_value = data[:posted_at_date].presence || data[:initiated_at_date].presence || data[:posted_at].presence || data[:created_at].presence

      case date_value
      when Date
        date_value
      when Time, DateTime
        date_value.to_date
      when String
        Date.parse(date_value)
      else
        nil
      end
    rescue ArgumentError, TypeError
      nil
    end

    def determine_sync_start_date(brex_account)
      return sync_start_date if sync_start_date.present?

      if brex_account.raw_transactions_payload.to_a.any?
        brex_item.last_synced_at ? brex_item.last_synced_at - 7.days : 90.days.ago
      else
        account_baseline = brex_account.created_at || Time.current
        [ account_baseline - 7.days, 90.days.ago ].max
      end
    end

    def mark_requires_update_if_credentials_error(error)
      return unless error.error_type.in?([ :unauthorized, :access_forbidden ])

      BrexItem::LegacyAccess.with_snapshot(brex_item, expected_context: @transport_context) { |fresh| fresh.update!(status: :requires_update) }
    rescue *BrexItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue => update_error
      Rails.logger.error "BrexItem::Importer - Failed to update item status: #{update_error.message}"
    end

    def failed_result(error)
      {
        success: false,
        error: error,
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end

    def verify_request!
      BrexItem::LegacyAccess.with_item(brex_item) do |fresh|
        BrexItem::LegacyAccess.verify_transport!(fresh, @transport_context)
        BrexItem::LegacyAccess.assert_transport!
      end
    end
end
