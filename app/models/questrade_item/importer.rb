# frozen_string_literal: true

class QuestradeItem::Importer
  include SyncStats::Collector
  include QuestradeAccount::DataHelpers

  # Chunk size for fetching activities
  ACTIVITY_CHUNK_DAYS = 365
  MAX_ACTIVITY_CHUNKS = 3 # Up to 3 years of history

  # Minimum existing activities required before using incremental sync
  MINIMUM_HISTORY_FOR_INCREMENTAL = 10

  attr_reader :questrade_item, :questrade_provider, :sync

  def initialize(questrade_item, sync: nil)
    @questrade_item = questrade_item
    @sync = sync
  end

  def import
    QuestradeItem::CredentialSession.with(questrade_item, sync: sync) do |session, current_sync|
      @session, @questrade_item, @sync = session, session.item, current_sync
      @questrade_provider = session.provider
      import_admitted
    end
  end

  private

    def import_admitted
      Rails.logger.info "QuestradeItem::Importer - Starting import for item #{questrade_item.id}"

      # Step 1: Fetch and store all accounts
      import_accounts

      # Step 2: For LINKED accounts only, fetch data
      # Unlinked accounts just need basic info (name, balance) for the setup modal
      linked_accounts = QuestradeAccount
        .where(questrade_item_id: questrade_item.id)
        .joins(:account_provider)

      Rails.logger.info "QuestradeItem::Importer - Found #{linked_accounts.count} linked accounts to process"

      linked_accounts.each do |questrade_account|
        Rails.logger.info "QuestradeItem::Importer - Processing linked account #{questrade_account.id}"
        import_account_data(questrade_account)
      end

      # Update raw payload on the item
      questrade_item.upsert_questrade_snapshot!(stats)
    rescue *QuestradeItem::CredentialSession::DENIAL_ERRORS
      raise
    rescue Provider::Questrade::AuthenticationError
      @session.require_update!
      raise
    end

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.reload.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_accounts
      Rails.logger.info "QuestradeItem::Importer - Fetching accounts"

      response = questrade_provider.list_accounts
      accounts_data = Array(response.is_a?(Hash) ? response[:accounts] : response)

      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      stats["total_accounts"] = accounts_data.size

      # Track upstream account IDs to detect removed accounts
      upstream_account_ids = []

      accounts_data.each do |account_data|
        begin
          account_data = account_data.with_indifferent_access if account_data.is_a?(Hash)
          import_account(account_data)
          number = (account_data[:number] || account_data[:id]).to_s
          upstream_account_ids << number if number.present?
        rescue *QuestradeItem::CredentialSession::DENIAL_ERRORS, Provider::Questrade::AuthenticationError
          raise
        rescue => e
          Rails.logger.error "QuestradeItem::Importer - Failed to import account: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_data: account_data)
        end
      end

      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids)
    end

    def import_account(account_data)
      questrade_account_id = (account_data[:number] || account_data[:id]).to_s
      return if questrade_account_id.blank?

      questrade_account = questrade_item.questrade_accounts.find_or_initialize_by(
        questrade_account_id: questrade_account_id
      )
      questrade_account.upsert_from_questrade!(account_data)

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end


    def import_account_data(questrade_account)
      QuestradeItem::LegacyAccess.with_account(questrade_account, operation: :ingest) do |current|
        # Per-currency balances (cash) -> total anchor + cash holdings
        store_balances(current)

        # Import holdings
        import_holdings(current)

        # Import activities
        import_activities(current)
      end
    end

    # Fetch per-currency balances. Stores primary-currency cash in cash_balance
    # (the rest become cash holdings) and the combined total equity used as the
    # account's current-balance anchor.
    def store_balances(questrade_account)
      context = QuestradeItem::LegacyAccess.capture_context(questrade_account)
      response = questrade_provider.get_balances(account_id: questrade_account.questrade_account_id)
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      per = Array(response.is_a?(Hash) ? response[:perCurrencyBalances] : nil)
      combined = Array(response.is_a?(Hash) ? response[:combinedBalances] : nil).map { |b| b.with_indifferent_access }
      QuestradeItem::LegacyAccess.with_snapshot(questrade_account, expected_context: context) do |fresh|
        fresh.send(:persist_balances!, per) if per.any?
        entry = combined.find { |b| b[:currency] == fresh.currency } || combined.first
        total = entry && (entry[:totalEquity] || entry[:marketValue])
        fresh.update!(current_balance: total) if total.present?
      end
      questrade_account.reload
    rescue *QuestradeItem::CredentialSession::DENIAL_ERRORS, Provider::Questrade::AuthenticationError
      raise
    rescue => e
      Rails.logger.warn "QuestradeItem::Importer - Failed to fetch balances for account #{questrade_account.id}: #{e.message}"
    end

    def import_holdings(questrade_account)
      Rails.logger.info "QuestradeItem::Importer - Fetching holdings for account #{questrade_account.id}"

      begin
        context = QuestradeItem::LegacyAccess.capture_context(questrade_account)
        response = questrade_provider.get_holdings(account_id: questrade_account.questrade_account_id)
        holdings_data = Array(response.is_a?(Hash) ? response[:positions] : response)

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        if holdings_data.any?
          # Convert SDK objects to hashes for storage
          holdings_hashes = holdings_data.map { |h| sdk_object_to_hash(h) }
          holdings_hashes = enrich_positions_with_currency(holdings_hashes)
          questrade_account.upsert_holdings_snapshot!(holdings_hashes, expected_context: context)
          stats["holdings_found"] = stats.fetch("holdings_found", 0) + holdings_data.size
        end
      rescue *QuestradeItem::CredentialSession::DENIAL_ERRORS, Provider::Questrade::AuthenticationError
        raise
      rescue => e
        Rails.logger.warn "QuestradeItem::Importer - Failed to fetch holdings: #{e.message}"
        register_error(e, context: "holdings", account_id: questrade_account.id)
      end
    end

    # Questrade positions omit currency. Tag each position with its symbol's
    # currency (via /v1/symbols) so USD holdings aren't mislabeled as the
    # account's CAD currency.
    def enrich_positions_with_currency(positions)
      ids = positions.filter_map { |p| p.with_indifferent_access[:symbolId] }.uniq
      return positions if ids.empty?

      currency_by_id = {}
      begin
        resp = questrade_provider.get_symbols(ids: ids)
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
        Array(resp.is_a?(Hash) ? resp[:symbols] : nil).each do |sym|
          sym = sym.with_indifferent_access
          currency_by_id[sym[:symbolId]] = sym[:currency]
        end
      rescue *QuestradeItem::CredentialSession::DENIAL_ERRORS, Provider::Questrade::AuthenticationError
        raise
      rescue => e
        Rails.logger.warn "QuestradeItem::Importer - symbol currency lookup failed: #{e.message}"
        return positions
      end

      positions.map do |p|
        p = p.with_indifferent_access
        cur = currency_by_id[p[:symbolId]]
        p[:currency] = cur if cur.present? && p[:currency].blank?
        p
      end
    end

    def import_activities(questrade_account)
      Rails.logger.info "QuestradeItem::Importer - Fetching activities for account #{questrade_account.id}"

      begin
        context = QuestradeItem::LegacyAccess.capture_context(questrade_account)
        # Determine date range
        start_date = calculate_start_date(questrade_account)
        end_date = Date.current

        response = questrade_provider.get_activities(
          account_id: questrade_account.questrade_account_id,
          start_date: start_date,
          end_date: end_date
        )
        activities_data = Array(response.is_a?(Hash) ? response[:activities] : response)

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        if activities_data.any?
          # Convert SDK objects to hashes and merge with existing
          activities_hashes = activities_data.map { |a| sdk_object_to_hash(a) }
          merged = merge_activities(questrade_account.raw_activities_payload || [], activities_hashes)
          questrade_account.upsert_activities_snapshot!(merged, expected_context: context)
          stats["activities_found"] = stats.fetch("activities_found", 0) + activities_data.size
        elsif fresh_linked_account?(questrade_account)
          # Fresh account with no activities - schedule background fetch
          schedule_background_activities_fetch(questrade_account, start_date)
        end
      rescue *QuestradeItem::CredentialSession::DENIAL_ERRORS, Provider::Questrade::AuthenticationError
        raise
      rescue => e
        Rails.logger.warn "QuestradeItem::Importer - Failed to fetch activities: #{e.message}"
        register_error(e, context: "activities", account_id: questrade_account.id)
      end
    end

    def calculate_start_date(questrade_account)
      # Use user-specified start date if available
      user_start = questrade_account.sync_start_date
      return user_start if user_start.present?

      # For accounts with existing history, use incremental sync
      existing_count = (questrade_account.raw_activities_payload || []).size
      if existing_count >= MINIMUM_HISTORY_FOR_INCREMENTAL && questrade_account.last_activities_sync.present?
        # Incremental: go back 30 days from last sync to catch updates
        (questrade_account.last_activities_sync - 30.days).to_date
      else
        # Full sync: go back up to 3 years
        (ACTIVITY_CHUNK_DAYS * MAX_ACTIVITY_CHUNKS).days.ago.to_date
      end
    end

    def fresh_linked_account?(questrade_account)
      # Account was just linked and has no activity history yet
      questrade_account.last_activities_sync.nil? &&
        (questrade_account.raw_activities_payload || []).empty?
    end

    def schedule_background_activities_fetch(questrade_account, start_date)
      Rails.logger.info "QuestradeItem::Importer - Scheduling background activities fetch for account #{questrade_account.id}"

      QuestradeActivitiesFetchJob.enqueue_for(questrade_account, start_date: start_date, sync: sync)
    end

    def merge_activities(existing, new_activities)
      # Merge by ID, preferring newer data
      by_id = {}
      existing.each { |a| by_id[activity_key(a)] = a }
      new_activities.each { |a| by_id[activity_key(a)] = a }
      by_id.values
    end

    def activity_key(activity)
      activity = activity.with_indifferent_access if activity.is_a?(Hash)
      # Questrade activities have no id; key on the immutable fields (same basis
      # as the processor's synthesized external_id) to dedup across syncs.
      [ activity[:transactionDate], activity[:action], activity[:symbolId],
        activity[:netAmount], activity[:description], activity[:currency], activity[:type] ].join("-")
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      # Find accounts that exist locally but not upstream
      removed = questrade_item.questrade_accounts
        .where.not(questrade_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "QuestradeItem::Importer - Pruning #{removed.count} removed accounts"
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
