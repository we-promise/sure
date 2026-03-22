# frozen_string_literal: true

class IndexaCapitalItem::Importer
  include SyncStats::Collector
  include IndexaCapitalAccount::DataHelpers

  attr_reader :indexa_capital_item, :indexa_capital_provider, :sync

  def initialize(indexa_capital_item, indexa_capital_provider:, sync: nil)
    @indexa_capital_item = indexa_capital_item
    @indexa_capital_provider = indexa_capital_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "IndexaCapitalItem::Importer - Starting import for item #{indexa_capital_item.id}"

    unless indexa_capital_provider
      raise CredentialsError, "No IndexaCapital provider configured for item #{indexa_capital_item.id}"
    end

    # Step 1: Fetch and store all accounts
    import_accounts

    # Step 2: For LINKED accounts only, fetch holdings data
    linked_accounts = IndexaCapitalAccount
      .where(indexa_capital_item_id: indexa_capital_item.id)
      .joins(:account_provider)

    Rails.logger.info "IndexaCapitalItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |indexa_capital_account|
      Rails.logger.info "IndexaCapitalItem::Importer - Processing linked account #{indexa_capital_account.id}"
      import_holdings(indexa_capital_account)
    end

    # Update raw payload on the item
    indexa_capital_item.upsert_indexa_capital_snapshot!(stats)
  rescue Provider::IndexaCapital::AuthenticationError
    indexa_capital_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_accounts
      Rails.logger.info "IndexaCapitalItem::Importer - Fetching accounts from Indexa Capital API"

      accounts_data = indexa_capital_provider.list_accounts

      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      stats["total_accounts"] = accounts_data.size

      upstream_account_ids = []

      accounts_data.each do |account_data|
        import_account(account_data)
        upstream_account_ids << account_data[:account_number].to_s if account_data[:account_number]
      rescue => e
        Rails.logger.error "IndexaCapitalItem::Importer - Failed to import account: #{e.message}"
        stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
        register_error(e, account_data: account_data)
      end

      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids)
    end

    def import_account(account_data)
      account_number = account_data[:account_number].to_s
      return if account_number.blank?

      # Fetch current balance from performance endpoint
      begin
        balance = indexa_capital_provider.get_account_balance(account_number: account_number)
        account_data[:current_balance] = balance
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      rescue => e
        Rails.logger.warn "IndexaCapitalItem::Importer - Failed to fetch balance for #{account_number}: #{e.message}"
      end

      indexa_capital_account = indexa_capital_item.indexa_capital_accounts.find_or_initialize_by(
        indexa_capital_account_id: account_number
      )

      indexa_capital_account.upsert_from_indexa_capital!(account_data)

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    def import_holdings(indexa_capital_account)
      account_number = indexa_capital_account.indexa_capital_account_id
      Rails.logger.info "IndexaCapitalItem::Importer - Fetching holdings for account #{account_number}"

      begin
        holdings_data = indexa_capital_provider.get_holdings(account_number: account_number)

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        # The API returns fiscal-results which may be a hash with an array inside
        holdings_array = normalize_holdings_response(holdings_data)

        if holdings_array.any?
          holdings_hashes = holdings_array.map { |h| sdk_object_to_hash(h) }
          indexa_capital_account.upsert_holdings_snapshot!(holdings_hashes)
          stats["holdings_found"] = stats.fetch("holdings_found", 0) + holdings_array.size
        end
      rescue => e
        Rails.logger.warn "IndexaCapitalItem::Importer - Failed to fetch holdings: #{e.message}"
        register_error(e, context: "holdings", account_id: indexa_capital_account.id)
      end
    end

    # fiscal-results response may be an array or a hash containing an array
    def normalize_holdings_response(data)
      return data if data.is_a?(Array)
      return [] if data.nil?

      # Try common response shapes
      data[:fiscal_results] || data[:results] || data[:positions] || data[:data] || []
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      removed = indexa_capital_item.indexa_capital_accounts
        .where.not(indexa_capital_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "IndexaCapitalItem::Importer - Pruning #{removed.count} removed accounts"
        removed.destroy_all
      end
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end
end
