# frozen_string_literal: true

class IndexaCapitalItem::Importer
  include SyncStats::Collector
  include IndexaCapitalAccount::DataHelpers

  # Chunk size for fetching activities
  ACTIVITY_CHUNK_DAYS = 365
  MAX_ACTIVITY_CHUNKS = 3 # Up to 3 years of history

  # Minimum existing activities required before using incremental sync
  MINIMUM_HISTORY_FOR_INCREMENTAL = 10

  attr_reader :indexa_capital_item, :indexa_capital_provider, :sync

  def initialize(indexa_capital_item, indexa_capital_provider:, sync: nil)
    @indexa_capital_item = indexa_capital_item
    @indexa_capital_provider = indexa_capital_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "IndexaCapitalItem::Importer - Starting import for item #{indexa_capital_item.id}"

    credentials = indexa_capital_item.indexa_capital_credentials
    unless credentials
      raise CredentialsError, "No IndexaCapital credentials configured for item #{indexa_capital_item.id}"
    end

    # Step 1: Fetch and store all accounts
    import_accounts(credentials)

    # Step 2: For LINKED accounts only, fetch data
    # Unlinked accounts just need basic info (name, balance) for the setup modal
    linked_accounts = IndexaCapitalAccount
      .where(indexa_capital_item_id: indexa_capital_item.id)
      .joins(:account_provider)

    Rails.logger.info "IndexaCapitalItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |indexa_capital_account|
      Rails.logger.info "IndexaCapitalItem::Importer - Processing linked account #{indexa_capital_account.id}"
      import_account_data(indexa_capital_account, credentials)
    end

    # Update raw payload on the item
    indexa_capital_item.upsert_indexa_capital_snapshot!(stats)
  rescue Provider::IndexaCapital::AuthenticationError => e
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

    def import_accounts(credentials)
      Rails.logger.info "IndexaCapitalItem::Importer - Fetching accounts"

      # TODO: Implement API call to fetch accounts
      # accounts_data = indexa_capital_provider.list_accounts(...)
      accounts_data = []

      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      stats["total_accounts"] = accounts_data.size

      # Track upstream account IDs to detect removed accounts
      upstream_account_ids = []

      accounts_data.each do |account_data|
        begin
          import_account(account_data, credentials)
          # TODO: Extract account ID from your provider's response format
          # upstream_account_ids << account_data[:id].to_s if account_data[:id]
        rescue => e
          Rails.logger.error "IndexaCapitalItem::Importer - Failed to import account: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_data: account_data)
        end
      end

      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids)
    end

    def import_account(account_data, credentials)
      # TODO: Customize based on your provider's account ID field
      # indexa_capital_account_id = account_data[:id].to_s
      # return if indexa_capital_account_id.blank?

      # indexa_capital_account = indexa_capital_item.indexa_capital_accounts.find_or_initialize_by(
      #   indexa_capital_account_id: indexa_capital_account_id
      # )

      # Update from API data
      # indexa_capital_account.upsert_from_indexa_capital!(account_data)

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    def import_account_data(indexa_capital_account, credentials)
      # Import holdings
      import_holdings(indexa_capital_account, credentials)

      # Import activities
      import_activities(indexa_capital_account, credentials)
    end

    def import_holdings(indexa_capital_account, credentials)
      Rails.logger.info "IndexaCapitalItem::Importer - Fetching holdings for account #{indexa_capital_account.id}"

      begin
        # TODO: Implement API call to fetch holdings
        # holdings_data = indexa_capital_provider.get_holdings(account_id: indexa_capital_account.indexa_capital_account_id)
        holdings_data = []

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        if holdings_data.any?
          # Convert SDK objects to hashes for storage
          holdings_hashes = holdings_data.map { |h| sdk_object_to_hash(h) }
          indexa_capital_account.upsert_holdings_snapshot!(holdings_hashes)
          stats["holdings_found"] = stats.fetch("holdings_found", 0) + holdings_data.size
        end
      rescue => e
        Rails.logger.warn "IndexaCapitalItem::Importer - Failed to fetch holdings: #{e.message}"
        register_error(e, context: "holdings", account_id: indexa_capital_account.id)
      end
    end

    def import_activities(indexa_capital_account, credentials)
      Rails.logger.info "IndexaCapitalItem::Importer - Fetching activities for account #{indexa_capital_account.id}"

      begin
        # Determine date range
        start_date = calculate_start_date(indexa_capital_account)
        end_date = Date.current

        # TODO: Implement API call to fetch activities
        # activities_data = indexa_capital_provider.get_activities(
        #   account_id: indexa_capital_account.indexa_capital_account_id,
        #   start_date: start_date,
        #   end_date: end_date
        # )
        activities_data = []

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        if activities_data.any?
          # Convert SDK objects to hashes and merge with existing
          activities_hashes = activities_data.map { |a| sdk_object_to_hash(a) }
          merged = merge_activities(indexa_capital_account.raw_activities_payload || [], activities_hashes)
          indexa_capital_account.upsert_activities_snapshot!(merged)
          stats["activities_found"] = stats.fetch("activities_found", 0) + activities_data.size
        elsif fresh_linked_account?(indexa_capital_account)
          # Fresh account with no activities - schedule background fetch
          schedule_background_activities_fetch(indexa_capital_account, start_date)
        end
      rescue => e
        Rails.logger.warn "IndexaCapitalItem::Importer - Failed to fetch activities: #{e.message}"
        register_error(e, context: "activities", account_id: indexa_capital_account.id)
      end
    end

    def calculate_start_date(indexa_capital_account)
      # Use user-specified start date if available
      user_start = indexa_capital_account.sync_start_date
      return user_start if user_start.present?

      # For accounts with existing history, use incremental sync
      existing_count = (indexa_capital_account.raw_activities_payload || []).size
      if existing_count >= MINIMUM_HISTORY_FOR_INCREMENTAL && indexa_capital_account.last_activities_sync.present?
        # Incremental: go back 30 days from last sync to catch updates
        (indexa_capital_account.last_activities_sync - 30.days).to_date
      else
        # Full sync: go back up to 3 years
        (ACTIVITY_CHUNK_DAYS * MAX_ACTIVITY_CHUNKS).days.ago.to_date
      end
    end

    def fresh_linked_account?(indexa_capital_account)
      # Account was just linked and has no activity history yet
      indexa_capital_account.last_activities_sync.nil? &&
        (indexa_capital_account.raw_activities_payload || []).empty?
    end

    def schedule_background_activities_fetch(indexa_capital_account, start_date)
      return if indexa_capital_account.activities_fetch_pending?

      Rails.logger.info "IndexaCapitalItem::Importer - Scheduling background activities fetch for account #{indexa_capital_account.id}"

      indexa_capital_account.update!(activities_fetch_pending: true)
      IndexaCapitalActivitiesFetchJob.perform_later(indexa_capital_account, start_date: start_date)
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
      # Use ID if available, otherwise generate key from date/type/amount
      activity[:id] || activity["id"] ||
        [ activity[:date], activity[:type], activity[:amount], activity[:symbol] ].join("-")
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      # Find accounts that exist locally but not upstream
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
