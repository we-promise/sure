require "digest/md5"

class AkahuItem::Importer
  Access = AkahuItem::LegacyAccess
  MAX_ROWS = 20_000
  MAX_BYTES = 16 * 1024 * 1024
  attr_reader :akahu_item, :akahu_provider

  def initialize(akahu_item, akahu_provider: nil)
    @akahu_item = akahu_item
    @akahu_provider = akahu_provider
    @provided_context = Access.transport_context(akahu_item) if akahu_provider
  end

  def import
    Access.with_item(akahu_item) do |current|
      Access.assert_transport!
      Access.verify_transport!(current, @provided_context) if @provided_context
      @akahu_item = current
      @transport_context = Access.transport_context(current)
      @akahu_provider ||= current.akahu_provider
      raise Provider::Akahu::AkahuError.new("Akahu provider is not configured", :configuration_error) unless akahu_provider
      if akahu_provider.is_a?(Provider::Akahu) && (akahu_provider.app_token != current.app_token.to_s.strip ||
          akahu_provider.user_token != current.user_token.to_s.strip)
        raise Access::Fence::OwnershipChanged, "Akahu client does not match the admitted credentials"
      end
      import_admitted
    end
  end

  private def import_admitted
    Rails.logger.info "AkahuItem::Importer - Starting import for item #{akahu_item.id}"

    @pending_inventories = {}
    @account_contexts = akahu_item.akahu_accounts.order(:id).limit(MAX_ROWS + 1).to_a
    raise Access::Fence::InvalidSource, "Akahu account inventory exceeds its bound" if @account_contexts.size > MAX_ROWS
    @account_contexts = @account_contexts.to_h { |source| [ source.account_id, Access.source_context(source) ] }
    accounts_data = fetch_accounts_data
    return failed_result("Failed to fetch accounts data") unless accounts_data

    akahu_item.upsert_akahu_snapshot!(accounts_data, expected_context: @transport_context)

    account_stats = import_accounts(accounts_data)
    @transaction_accounts = akahu_item.akahu_accounts.joins(:account).merge(Account.visible).order(:id).limit(MAX_ROWS + 1).to_a
    raise Access::Fence::InvalidSource, "Akahu linked inventory exceeds its bound" if @transaction_accounts.size > MAX_ROWS
    @transaction_contexts = @transaction_accounts.to_h { |source| [ source.id, Access.source_context(source) ] }
    pending_result = fetch_pending_transactions_by_account
    transaction_stats = import_transactions(pending_result)

    Rails.logger.info(
      "AkahuItem::Importer - Completed import for item #{akahu_item.id}: " \
      "#{account_stats[:updated]} accounts updated, #{account_stats[:created]} new accounts discovered, " \
      "#{transaction_stats[:imported]} transactions"
    )

    {
      success: account_stats[:failed].zero? && transaction_stats[:failed].zero? && pending_result[:success],
      error: pending_result[:success] ? nil : pending_result[:error],
      accounts_updated: account_stats[:updated],
      accounts_created: account_stats[:created],
      accounts_failed: account_stats[:failed],
      transactions_imported: transaction_stats[:imported],
      transactions_failed: transaction_stats[:failed],
      pending_inventories: @pending_inventories.freeze
    }
  end

  private

    def fetch_accounts_data
      verify_request!
      items = akahu_provider.get_accounts
      validate_rows!(items)
      { items: items }
    rescue *Access::DENIAL_ERRORS
      raise
    rescue Provider::Akahu::AkahuError => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      capture_failure(e, "accounts")
      Rails.logger.error "AkahuItem::Importer - Akahu API error: #{e.error_type}"
      nil
    rescue JSON::ParserError => e
      capture_failure(e, "accounts")
      Rails.logger.error "AkahuItem::Importer - Failed to parse Akahu API response: #{e.class}"
      nil
    rescue => e
      capture_failure(e, "accounts")
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
          akahu_account.upsert_akahu_snapshot!(account, expected_item_context: @transport_context)
          stats[:created] += 1
        end
      rescue *Access::DENIAL_ERRORS
        raise
      rescue => e
        capture_failure(e, "account_snapshot")
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

      expected = @account_contexts.fetch(account_id.to_s) do
        raise Access::Fence::OwnershipChanged, "Akahu account appeared after request capture"
      end
      akahu_account.upsert_akahu_snapshot!(account, expected_context: expected, expected_item_context: @transport_context)
    end

    def fetch_pending_transactions_by_account
      verify_request!
      pending_transactions = akahu_provider.get_pending_transactions
      validate_rows!(pending_transactions)

      by_account = pending_transactions.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |transaction, grouped|
        data = transaction.with_indifferent_access
        account_id = data[:_account].presence || data[:account].presence || data[:account_id].presence
        unless (account_id.is_a?(String) || account_id.is_a?(Integer)) && account_id.to_s.present?
          raise Provider::Akahu::AkahuError.new("Pending transaction has no account identity", :invalid_response)
        end

        grouped[account_id.to_s] << data.merge(_pending: true)
      end

      { success: true, by_account: by_account }
    rescue *Access::DENIAL_ERRORS
      raise
    rescue StandardError => e
      capture_failure(e, "pending_inventory")
      error_label = e.respond_to?(:error_type) ? e.error_type : e.class.name
      Rails.logger.warn "AkahuItem::Importer - Failed to fetch pending transactions: #{error_label}"
      { success: false, by_account: Hash.new { |hash, key| hash[key] = [] }, error: I18n.t("akahu_item.errors.pending_transactions_failed") }
    end

    def import_transactions(pending_result)
      stats = { imported: 0, failed: 0 }
      pending_by_account = pending_result[:by_account]
      pending_refresh_succeeded = pending_result[:success]

      @transaction_accounts.each do |akahu_account|
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
      rescue *Access::DENIAL_ERRORS
        raise
      rescue => e
        capture_failure(e, "transactions", source: akahu_account)
        stats[:failed] += 1
        Rails.logger.error "AkahuItem::Importer - Failed to fetch/store transactions for Akahu account #{akahu_account.id}: #{e.class}"
      end

      stats
    end

    def fetch_and_store_transactions(akahu_account, pending_transactions, pending_refresh_succeeded:)
      expected_context = @transaction_contexts.fetch(akahu_account.id)
      start_date = determine_sync_start_date(akahu_account)
      Rails.logger.info "AkahuItem::Importer - Fetching transactions for Akahu account #{akahu_account.id} from #{start_date}"

      verify_request!
      posted_transactions = akahu_provider.get_account_transactions(
        account_id: akahu_account.account_id,
        start_date: start_date
      )
      validate_rows!(posted_transactions)
      unless posted_transactions.all? { |row| transaction_account_id(row) == akahu_account.account_id.to_s }
        raise Access::Fence::OwnershipChanged, "Akahu transaction belongs to another source account"
      end

      store_transactions(
        akahu_account,
        posted_transactions: Array(posted_transactions),
        pending_transactions: Array(pending_transactions),
        replace_pending: pending_refresh_succeeded, expected_context: expected_context
      )

      { success: true, transactions_count: Array(posted_transactions).count + Array(pending_transactions).count }
    rescue *Access::DENIAL_ERRORS
      raise
    rescue Provider::Akahu::AkahuError => e
      capture_failure(e, "transactions", source: akahu_account)
      Rails.logger.error "AkahuItem::Importer - Akahu API error for account #{akahu_account.id}: #{e.error_type}"
      { success: false, transactions_count: 0, error: I18n.t("akahu_item.errors.transactions_failed") }
    rescue JSON::ParserError => e
      capture_failure(e, "transactions", source: akahu_account)
      Rails.logger.error "AkahuItem::Importer - Failed to parse transaction response for account #{akahu_account.id}: #{e.class}"
      { success: false, transactions_count: 0, error: "Failed to parse response" }
    rescue => e
      capture_failure(e, "transactions", source: akahu_account)
      Rails.logger.error "AkahuItem::Importer - Unexpected error fetching transactions for account #{akahu_account.id}: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, transactions_count: 0, error: I18n.t("akahu_item.errors.transactions_failed") }
    end

    def store_transactions(akahu_account, posted_transactions:, pending_transactions:, replace_pending:, expected_context:)
      receipt = Access.with_source_snapshot(akahu_account, expected_context: expected_context, expected_item_context: @transport_context) do |current|
        merge_transactions(current, posted_transactions: posted_transactions, pending_transactions: pending_transactions, replace_pending: replace_pending)
        if replace_pending
          AkahuAccount::PendingCleanup.capture(source: current, pending_rows: pending_transactions,
            source_context: Access.source_context(current), transport_context: @transport_context)
        end
      end
      @pending_inventories[akahu_account.id] = receipt if receipt
      akahu_account.reload
    end

    def merge_transactions(akahu_account, posted_transactions:, pending_transactions:, replace_pending:)
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

      if final_transactions != existing_transactions || (replace_pending && akahu_account.raw_transactions_payload.nil?)
        Rails.logger.info(
          "AkahuItem::Importer - Storing #{new_posted_transactions.count} new posted transactions " \
          "and #{current_pending_transactions.count} current pending transactions " \
          "(#{existing_transactions.count} existing) for account #{akahu_account.account_id}"
        )
        akahu_account.update!(raw_transactions_payload: final_transactions)
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
        # Initial sync: omit the start date entirely. Akahu's transactions
        # endpoint defaults to the full accessible range when no start is given,
        # so this pulls the connection's complete history instead of clamping it
        # to a fixed lookback window (which truncated apps with >5 years of data).
        nil
      end
    end

    def mark_requires_update!
      Access.with_snapshot(akahu_item, expected_context: @transport_context) { |current| current.update!(status: :requires_update) }
    rescue *Access::DENIAL_ERRORS
      raise
    rescue => e
      capture_failure(e, "status")
      Rails.logger.error "AkahuItem::Importer - Failed to update item status: #{e.message}"
    end

    def failed_result(error)
      { success: false, error: error, accounts_imported: 0, transactions_imported: 0, pending_inventories: {}.freeze }
    end

    def verify_request!
      Access.assert_transport!
      Access.verify_transport!(AkahuItem.find(akahu_item.id), @transport_context)
    rescue ActiveRecord::RecordNotFound
      raise Access::Fence::OwnershipChanged, "Akahu request owner disappeared", cause: nil
    end

    def validate_rows!(rows)
      unless rows.is_a?(Array) && rows.size <= MAX_ROWS && rows.all? { |row| row.is_a?(Hash) } &&
          JSON.generate(rows).bytesize <= MAX_BYTES
        raise Provider::Akahu::AkahuError.new("Akahu response exceeds its complete row contract", :invalid_response)
      end
    end

    def transaction_account_id(row)
      data = row.with_indifferent_access
      (data[:_account].presence || data[:account].presence || data[:account_id].presence)&.to_s
    end

    def capture_failure(error, stage, source: nil)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Akahu legacy import requires retry or review",
        source: self.class.name, provider_key: "akahu", family_id: akahu_item.family_id,
        metadata: { akahu_item_id: akahu_item.id, akahu_account_id: source&.id, stage: stage, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
