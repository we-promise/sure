class SnaptradeItem::Importer
  include SyncStats::Collector
  include SnaptradeAccount::DataHelpers

  attr_reader :snaptrade_item, :snaptrade_provider, :sync

  # Chunk size for fetching activities (365 days per chunk)
  ACTIVITY_CHUNK_DAYS = 365
  MAX_ACTIVITY_CHUNKS = 3 # Up to 3 years of history

  # Minimum existing activities required before using incremental sync
  # Prevents treating a partially synced account as "caught up"
  MINIMUM_HISTORY_FOR_INCREMENTAL = 10

  def initialize(snaptrade_item, snaptrade_provider:, sync: nil)
    @snaptrade_item = snaptrade_item
    @snaptrade_provider = snaptrade_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "SnaptradeItem::Importer - Starting import for item #{snaptrade_item.id}"

    credentials = snaptrade_item.snaptrade_credentials
    unless credentials
      raise CredentialsError, "No SnapTrade credentials configured for item #{snaptrade_item.id}"
    end

    # Step 1: Fetch and store all accounts
    import_accounts(credentials)

    # Step 2: For LINKED accounts only, fetch holdings and activities
    # Unlinked accounts just need basic info (name, balance) for the setup modal
    # Query directly to avoid any association caching issues
    linked_accounts = SnaptradeAccount
      .where(snaptrade_item_id: snaptrade_item.id)
      .joins(:account_provider)

    Rails.logger.info "SnaptradeItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |snaptrade_account|
      Rails.logger.info "SnaptradeItem::Importer - Processing linked account #{snaptrade_account.id} (#{snaptrade_account.snaptrade_account_id})"
      import_account_data(snaptrade_account, credentials)
    end

    # Update raw payload on the item
    snaptrade_item.upsert_snaptrade_snapshot!(stats)
  rescue Provider::Snaptrade::AuthenticationError => e
    snaptrade_item.update!(status: :requires_update)
    raise
  end

  private

    # Extract activities array from API response
    # get_account_activities returns a paginated object with .data accessor
    # This handles both paginated responses and plain arrays
    def extract_activities_from_response(response)
      if response.respond_to?(:data)
        # Paginated response (e.g., SnapTrade::PaginatedUniversalActivity)
        Rails.logger.info "SnaptradeItem::Importer - Paginated response, extracting .data (#{response.data&.size || 0} items)"
        response.data || []
      elsif response.is_a?(Array)
        # Direct array response
        Rails.logger.info "SnaptradeItem::Importer - Array response (#{response.size} items)"
        response
      else
        Rails.logger.warn "SnaptradeItem::Importer - Unexpected response type: #{response.class}"
        []
      end
    end

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_accounts(credentials)
      Rails.logger.info "SnaptradeItem::Importer - Fetching accounts"

      accounts_data = snaptrade_provider.list_accounts(
        user_id: credentials[:user_id],
        user_secret: credentials[:user_secret]
      )

      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      stats["total_accounts"] = accounts_data.size

      # Track upstream account IDs to detect removed accounts
      upstream_account_ids = []

      accounts_data.each do |account_data|
        begin
          import_account(account_data, credentials)
          upstream_account_ids << account_data.id.to_s if account_data.id
        rescue => e
          Rails.logger.error "SnaptradeItem::Importer - Failed to import account: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_data: account_data)
        end
      end

      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids)
    end

    def import_account(account_data, credentials)
      # Find or create the SnaptradeAccount by SnapTrade's account ID
      snaptrade_account_id = account_data.id.to_s
      return if snaptrade_account_id.blank?

      snaptrade_account = snaptrade_item.snaptrade_accounts.find_or_initialize_by(
        snaptrade_account_id: snaptrade_account_id
      )

      # Update from API data - pass raw SDK object, model handles conversion
      snaptrade_account.upsert_from_snaptrade!(account_data)

      # Fetch and store balances
      begin
        balances = snaptrade_provider.get_balances(
          user_id: credentials[:user_id],
          user_secret: credentials[:user_secret],
          account_id: snaptrade_account_id
        )
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        # Pass raw SDK objects - model handles conversion
        snaptrade_account.upsert_balances!(balances)
      rescue => e
        Rails.logger.warn "SnaptradeItem::Importer - Failed to fetch balances for account #{snaptrade_account_id}: #{e.message}"
      end

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    def import_account_data(snaptrade_account, credentials)
      snaptrade_account_id = snaptrade_account.snaptrade_account_id
      return if snaptrade_account_id.blank?

      # Import holdings
      import_holdings(snaptrade_account, credentials)

      # Import activities (chunked for history)
      import_activities(snaptrade_account, credentials)
    end

    def import_holdings(snaptrade_account, credentials)
      Rails.logger.info "SnaptradeItem::Importer - Fetching holdings for account #{snaptrade_account.id} (#{snaptrade_account.snaptrade_account_id})"

      begin
        holdings = snaptrade_provider.get_positions(
          user_id: credentials[:user_id],
          user_secret: credentials[:user_secret],
          account_id: snaptrade_account.snaptrade_account_id
        )
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        Rails.logger.info "SnaptradeItem::Importer - Got #{holdings.size} holdings from API"

        holdings_data = holdings.map { |h| sdk_object_to_hash(h) }

        # Log sample holding structure
        if holdings_data.first
          sample = holdings_data.first
          Rails.logger.info "SnaptradeItem::Importer - Sample holding: #{sample.keys.join(', ')}"
          if sample["symbol"]
            Rails.logger.info "SnaptradeItem::Importer - Sample symbol keys: #{sample['symbol'].keys.join(', ')}" if sample["symbol"].is_a?(Hash)
            Rails.logger.info "SnaptradeItem::Importer - Sample symbol.symbol: #{sample.dig('symbol', 'symbol')}"
            Rails.logger.info "SnaptradeItem::Importer - Sample symbol.description: #{sample.dig('symbol', 'description')}"
          end
        end

        snaptrade_account.upsert_holdings_snapshot!(holdings_data)

        stats["holdings_found"] = stats.fetch("holdings_found", 0) + holdings_data.size
      rescue => e
        Rails.logger.error "SnaptradeItem::Importer - Failed to fetch holdings: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
        register_error(e, context: "holdings", account_id: snaptrade_account.id)
      end
    end

    def import_activities(snaptrade_account, credentials)
      Rails.logger.info "SnaptradeItem::Importer - Fetching activities for account #{snaptrade_account.id} (#{snaptrade_account.snaptrade_account_id})"

      # Determine date range for fetching activities
      # Use first_transaction_date from sync_status to know how far back history goes
      first_tx_date = extract_first_transaction_date(snaptrade_account)
      existing_count = snaptrade_account.raw_activities_payload&.size || 0

      # User-configured sync start date acts as a floor - don't fetch activities before this date
      user_sync_start = snaptrade_account.sync_start_date

      # Only do incremental sync if we already have meaningful history
      # This ensures we do a full history fetch on first sync even if timestamps are set
      can_do_incremental = snaptrade_item.last_synced_at.present? &&
                           snaptrade_account.last_activities_sync.present? &&
                           existing_count >= MINIMUM_HISTORY_FOR_INCREMENTAL

      if can_do_incremental
        # Incremental sync - fetch from last sync minus buffer (synchronous)
        start_date = snaptrade_account.last_activities_sync - 30.days
        # Respect user's sync_start_date floor
        start_date = [ start_date, user_sync_start ].compact.max
        Rails.logger.info "SnaptradeItem::Importer - Incremental activities fetch from #{start_date} (existing: #{existing_count})"
        fetch_all_activities(snaptrade_account, credentials, start_date: start_date)
      else
        # Full history - use user's sync_start_date if set, otherwise first_transaction_date
        # Default to MAX_ACTIVITY_CHUNKS years ago to match chunk size
        default_start = (MAX_ACTIVITY_CHUNKS * ACTIVITY_CHUNK_DAYS).days.ago.to_date
        start_date = user_sync_start || first_tx_date || default_start
        Rails.logger.info "SnaptradeItem::Importer - Full history fetch from #{start_date} (user_sync_start: #{user_sync_start || 'none'}, first_tx_date: #{first_tx_date || 'unknown'}, existing: #{existing_count})"

        # Try to fetch activities synchronously first
        fetched_count = fetch_all_activities(snaptrade_account, credentials, start_date: start_date)

        if fetched_count == 0 && existing_count == 0
          # On fresh connection, SnapTrade may need time to sync data from brokerage
          # Dispatch background job with retry logic instead of blocking the worker
          Rails.logger.info(
            "SnaptradeItem::Importer - No activities returned for account #{snaptrade_account.id}, " \
            "dispatching background fetch job (SnapTrade may still be syncing)"
          )

          SnaptradeActivitiesFetchJob.set(wait: 10.seconds).perform_later(
            snaptrade_account,
            start_date: start_date
          )

          # Mark the account as having pending activities
          # The background job will clear this flag when done
          snaptrade_account.update!(activities_fetch_pending: true)
        end
      end

      # Log what we have after fetching (may be 0 if job was dispatched)
      final_count = snaptrade_account.reload.raw_activities_payload&.size || 0
      Rails.logger.info "SnaptradeItem::Importer - Activities stored: #{final_count}"

      if final_count > 0 && snaptrade_account.raw_activities_payload.first
        sample = snaptrade_account.raw_activities_payload.first
        Rails.logger.info "SnaptradeItem::Importer - Sample activity keys: #{sample.keys.join(', ')}"
        Rails.logger.info "SnaptradeItem::Importer - Sample activity type: #{sample['type']}"
      end
    end

    # Extract first_transaction_date from account's sync_status
    # Checks multiple locations: raw_payload and raw_activities_payload
    def extract_first_transaction_date(snaptrade_account)
      # Try 1: Check raw_payload (from list_accounts)
      raw = snaptrade_account.raw_payload
      if raw.is_a?(Hash)
        date_str = raw.dig("sync_status", "transactions", "first_transaction_date")
        return Date.parse(date_str) if date_str.present?
      end

      # Try 2: Check activities payload (sync_status is nested in account object)
      activities = snaptrade_account.raw_activities_payload
      if activities.is_a?(Array) && activities.first.is_a?(Hash)
        date_str = activities.first.dig("account", "sync_status", "transactions", "first_transaction_date")
        return Date.parse(date_str) if date_str.present?
      end

      nil
    rescue ArgumentError, TypeError
      nil
    end

    # Fetch all activities using per-account endpoint with proper date range
    # Uses get_account_activities which returns paginated data for the specific account
    def fetch_all_activities(snaptrade_account, credentials, start_date:, end_date: nil)
      # Ensure dates are proper Date objects (not strings or other types)
      start_date = ensure_date(start_date) || 5.years.ago.to_date
      end_date = ensure_date(end_date) || Date.current
      all_activities = []

      Rails.logger.info "SnaptradeItem::Importer - Fetching activities from #{start_date} to #{end_date}"

      begin
        # Use get_account_activities (per-account endpoint) for better results
        response = snaptrade_provider.get_account_activities(
          user_id: credentials[:user_id],
          user_secret: credentials[:user_secret],
          account_id: snaptrade_account.snaptrade_account_id,
          start_date: start_date,
          end_date: end_date
        )
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        # Handle paginated response
        activities = extract_activities_from_response(response)
        Rails.logger.info "SnaptradeItem::Importer - get_account_activities returned #{activities.size} items"

        activities_data = activities.map { |a| sdk_object_to_hash(a) }
        all_activities.concat(activities_data)

        # If the per-account endpoint returned few results, also try the cross-account endpoint
        # as a fallback (some brokerages may work better with one or the other)
        if activities_data.size < 10 && (end_date - start_date).to_i > 365
          Rails.logger.info "SnaptradeItem::Importer - Few results from per-account endpoint, trying cross-account endpoint"
          cross_account_activities = fetch_via_cross_account_endpoint(
            snaptrade_account, credentials, start_date: start_date, end_date: end_date
          )

          if cross_account_activities.size > activities_data.size
            Rails.logger.info "SnaptradeItem::Importer - Cross-account endpoint returned more: #{cross_account_activities.size} vs #{activities_data.size}"
            all_activities = cross_account_activities
          end
        end

        # Only save if we actually got new activities
        # Don't upsert empty arrays as this sets last_activities_sync incorrectly
        if all_activities.any?
          existing = snaptrade_account.raw_activities_payload || []
          merged = merge_activities(existing, all_activities)
          snaptrade_account.upsert_activities_snapshot!(merged)
          stats["activities_found"] = stats.fetch("activities_found", 0) + all_activities.size
        end

        all_activities.size
      rescue => e
        Rails.logger.error "SnaptradeItem::Importer - Failed to fetch activities: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
        register_error(e, context: "activities", account_id: snaptrade_account.id)
        0
      end
    end

    # Fallback: try the cross-account endpoint which may work better for some brokerages
    def fetch_via_cross_account_endpoint(snaptrade_account, credentials, start_date:, end_date:)
      activities = snaptrade_provider.get_activities(
        user_id: credentials[:user_id],
        user_secret: credentials[:user_secret],
        start_date: start_date,
        end_date: end_date,
        accounts: snaptrade_account.snaptrade_account_id
      )
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      activities = activities || []
      activities.map { |a| sdk_object_to_hash(a) }
    rescue => e
      Rails.logger.warn "SnaptradeItem::Importer - Cross-account endpoint fallback failed: #{e.message}"
      []
    end

    # Merge activities, deduplicating by ID
    # Fallback key includes symbol to distinguish activities with same date/type/amount
    def merge_activities(existing, new_activities)
      by_id = {}

      existing.each do |activity|
        a = activity.with_indifferent_access
        key = a[:id] || activity_fallback_key(a)
        by_id[key] = activity
      end

      new_activities.each do |activity|
        a = activity.with_indifferent_access
        key = a[:id] || activity_fallback_key(a)
        by_id[key] = activity # Newer data wins
      end

      by_id.values
    end

    def activity_fallback_key(activity)
      symbol = activity.dig(:symbol, :symbol) || activity.dig("symbol", "symbol")
      [ activity[:settlement_date], activity[:type], activity[:amount], symbol ]
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.blank?

      # Find accounts that no longer exist upstream
      orphaned = snaptrade_item.snaptrade_accounts
        .where.not(snaptrade_account_id: upstream_account_ids)
        .where.not(snaptrade_account_id: nil)

      orphaned.each do |snaptrade_account|
        # Only delete if not linked to a Sure account
        if snaptrade_account.current_account.blank?
          Rails.logger.info "SnaptradeItem::Importer - Pruning orphaned account #{snaptrade_account.id}"
          snaptrade_account.destroy
          stats["accounts_pruned"] = stats.fetch("accounts_pruned", 0) + 1
        end
      end
    end

    def register_error(error, account_data: nil, context: nil, account_id: nil)
      # Extract account name safely from SDK object or hash
      account_name = extract_account_name(account_data)

      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context,
        account_id: account_id,
        account_name: account_name
      }.compact
      stats["errors"] = stats["errors"].last(10)
      stats["total_errors"] = stats.fetch("total_errors", 0) + 1
    end

    def extract_account_name(account_data)
      return nil if account_data.nil?

      if account_data.respond_to?(:name)
        account_data.name
      elsif account_data.respond_to?(:dig)
        account_data.dig(:name)
      elsif account_data.respond_to?(:[])
        account_data[:name]
      end
    end

    # Convert various date representations to a Date object
    def ensure_date(value)
      return nil if value.nil?
      return value if value.is_a?(Date)
      return value.to_date if value.is_a?(Time) || value.is_a?(DateTime) || value.is_a?(ActiveSupport::TimeWithZone)

      if value.is_a?(String)
        Date.parse(value)
      elsif value.respond_to?(:to_date)
        value.to_date
      else
        nil
      end
    rescue ArgumentError, TypeError
      nil
    end
end
