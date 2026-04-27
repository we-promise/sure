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

        holdings_array = normalize_holdings_response(holdings_data)

        # Pension plans return empty fiscal-results. Fall back to the portfolio
        # endpoint, which exposes positions for both mutual fund and pension
        # accounts in a uniform shape we can adapt to the same structure.
        if holdings_array.empty?
          Rails.logger.info "IndexaCapitalItem::Importer - fiscal-results empty for #{account_number}, falling back to /portfolio"
          portfolio_data = indexa_capital_provider.get_portfolio(account_number: account_number)
          stats["api_requests"] = stats.fetch("api_requests", 0) + 1
          holdings_array = positions_from_portfolio(portfolio_data)
        end

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

    # Adapt /accounts/{id}/portfolio positions into the shape that
    # HoldingsProcessor expects (i.e. the same field set as a
    # total_fiscal_results row). Adds a derived cost_price (per-share cost)
    # since portfolio rows only carry cost_amount.
    def positions_from_portfolio(portfolio_data)
      data = portfolio_data.is_a?(Hash) ? portfolio_data.with_indifferent_access : {}
      Array(data[:instrument_accounts]).flat_map do |account|
        Array(account.is_a?(Hash) ? account.with_indifferent_access[:positions] : nil).map do |pos|
          row = (pos.is_a?(Hash) ? pos.with_indifferent_access : {}).dup
          titles = row[:titles].to_d if row[:titles]
          cost_amount = row[:cost_amount].to_d if row[:cost_amount]
          if row[:cost_price].blank? && titles && titles.nonzero? && cost_amount
            row[:cost_price] = (cost_amount / titles).to_s
          end
          row
        end
      end
    end

    # fiscal-results response may be an array or a hash containing an array.
    # Prefer total_fiscal_results: it contains one aggregated row per security
    # with current titles/amount/cost. fiscal_results is per tax lot and also
    # includes historical rebalance events (e.g. virtual sells/buys that
    # generated tax events), so summing/iterating it over-counts the position.
    def normalize_holdings_response(data)
      return data if data.is_a?(Array)
      return [] if data.nil?

      data[:total_fiscal_results].presence ||
        data[:fiscal_results] ||
        data[:results] ||
        data[:positions] ||
        data[:data] ||
        []
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
