# frozen_string_literal: true

# SyncStats::Collector provides shared methods for collecting sync statistics
# across different provider syncers.
#
# This concern standardizes the stat collection interface so all providers
# can report consistent sync summaries.
#
# @example Include in a syncer class
#   class PlaidItem::Syncer
#     include SyncStats::Collector
#
#     def perform_sync(sync)
#       # ... sync logic ...
#       collect_setup_stats(sync, provider_accounts: plaid_item.plaid_accounts)
#       collect_transaction_stats(sync, account_ids: account_ids, source: "plaid")
#       # ...
#     end
#   end
#
module SyncStats
  module Collector
    extend ActiveSupport::Concern

    # Collects account setup statistics (total, linked, unlinked counts).
    #
    # @param sync [Sync] The sync record to update
    # @param provider_accounts [ActiveRecord::Relation] The provider accounts (e.g., SimplefinAccount, PlaidAccount)
    # @param linked_check [Proc, nil] Optional proc to check if an account is linked. If nil, uses default logic.
    # @return [Hash] The setup stats that were collected
    def collect_setup_stats(sync, provider_accounts:, linked_check: nil)
      return {} unless sync.respond_to?(:sync_stats)

      total_accounts = provider_accounts.count

      # Count linked accounts - either via custom check or default association check
      linked_count = if linked_check
        provider_accounts.count { |pa| linked_check.call(pa) }
      else
        # Default: check for current_account method or account association
        provider_accounts.count do |pa|
          (pa.respond_to?(:current_account) && pa.current_account.present?) ||
            (pa.respond_to?(:account) && pa.account.present?)
        end
      end

      unlinked_count = total_accounts - linked_count

      setup_stats = {
        "total_accounts" => total_accounts,
        "linked_accounts" => linked_count,
        "unlinked_accounts" => unlinked_count
      }

      merge_sync_stats(sync, setup_stats)
      setup_stats
    end

    # Collects transaction statistics (imported, updated, seen, skipped).
    #
    # @param sync [Sync] The sync record to update
    # @param account_ids [Array<String>] The account IDs to count transactions for
    # @param source [String] The transaction source (e.g., "simplefin", "plaid")
    # @param window_start [Time, nil] Start of the sync window (defaults to sync.created_at or 30 minutes ago)
    # @param window_end [Time, nil] End of the sync window (defaults to Time.current)
    # @return [Hash] The transaction stats that were collected
    def collect_transaction_stats(sync, account_ids:, source:, window_start: nil, window_end: nil)
      return {} unless sync.respond_to?(:sync_stats)
      return {} if account_ids.empty?

      window_start ||= sync.created_at || 30.minutes.ago
      window_end ||= Time.current

      tx_scope = Entry.where(account_id: account_ids, source: source, entryable_type: "Transaction")
      tx_imported = tx_scope.where(created_at: window_start..window_end).count
      tx_updated = tx_scope.where(updated_at: window_start..window_end)
                          .where.not(created_at: window_start..window_end).count
      tx_seen = tx_imported + tx_updated

      tx_stats = {
        "tx_imported" => tx_imported,
        "tx_updated" => tx_updated,
        "tx_seen" => tx_seen,
        "window_start" => window_start.iso8601,
        "window_end" => window_end.iso8601
      }

      merge_sync_stats(sync, tx_stats)
      tx_stats
    end

    # Collects holdings statistics.
    #
    # @param sync [Sync] The sync record to update
    # @param holdings_count [Integer] The number of holdings found/processed
    # @param label [String] The label for the stat ("found" or "processed")
    # @return [Hash] The holdings stats that were collected
    def collect_holdings_stats(sync, holdings_count:, label: "found")
      return {} unless sync.respond_to?(:sync_stats)

      key = label == "processed" ? "holdings_processed" : "holdings_found"
      holdings_stats = { key => holdings_count }

      merge_sync_stats(sync, holdings_stats)
      holdings_stats
    end

    # Collects trades statistics (investment activities like buy/sell).
    #
    # @param sync [Sync] The sync record to update
    # @param account_ids [Array<String>] The account IDs to count trades for
    # @param source [String] The trade source (e.g., "snaptrade", "plaid")
    # @param window_start [Time, nil] Start of the sync window (defaults to sync.created_at or 30 minutes ago)
    # @param window_end [Time, nil] End of the sync window (defaults to Time.current)
    # @return [Hash] The trades stats that were collected
    def collect_trades_stats(sync, account_ids:, source:, window_start: nil, window_end: nil)
      return {} unless sync.respond_to?(:sync_stats)
      return {} if account_ids.empty?

      window_start ||= sync.created_at || 30.minutes.ago
      window_end ||= Time.current

      trade_scope = Entry.where(account_id: account_ids, source: source, entryable_type: "Trade")
      trades_imported = trade_scope.where(created_at: window_start..window_end).count

      trades_stats = {
        "trades_imported" => trades_imported
      }

      merge_sync_stats(sync, trades_stats)
      trades_stats
    end

    # Collects health/error statistics.
    #
    # @param sync [Sync] The sync record to update
    # @param errors [Array<Hash>, nil] Array of error objects with :message and optional :category
    # @param rate_limited [Boolean] Whether the sync was rate limited
    # @param rate_limited_at [Time, nil] When rate limiting occurred
    # @return [Hash] The health stats that were collected
    def collect_health_stats(sync, errors: nil, rate_limited: false, rate_limited_at: nil)
      return {} unless sync.respond_to?(:sync_stats)

      health_stats = {
        "import_started" => true
      }

      if errors.present?
        health_stats["errors"] = errors.map do |e|
          e.is_a?(Hash) ? e.stringify_keys : { "message" => e.to_s }
        end
        health_stats["total_errors"] = errors.size
      else
        health_stats["total_errors"] = 0
      end

      if rate_limited
        health_stats["rate_limited"] = true
        health_stats["rate_limited_at"] = rate_limited_at&.iso8601
      end

      merge_sync_stats(sync, health_stats)
      health_stats
    end

    # Collects data quality warnings and notices.
    #
    # @param sync [Sync] The sync record to update
    # @param warnings [Integer] Number of data warnings
    # @param notices [Integer] Number of notices
    # @param details [Array<Hash>] Array of detail objects with :message and optional :severity
    # @return [Hash] The data quality stats that were collected
    def collect_data_quality_stats(sync, warnings: 0, notices: 0, details: [])
      return {} unless sync.respond_to?(:sync_stats)

      quality_stats = {
        "data_warnings" => warnings,
        "notices" => notices
      }

      if details.present?
        quality_stats["data_quality_details"] = details.map do |d|
          d.is_a?(Hash) ? d.stringify_keys : { "message" => d.to_s, "severity" => "info" }
        end
      end

      merge_sync_stats(sync, quality_stats)
      quality_stats
    end

    # Marks the sync as having started import (used for health indicator).
    #
    # @param sync [Sync] The sync record to update
    def mark_import_started(sync)
      return unless sync.respond_to?(:sync_stats)

      merge_sync_stats(sync, { "import_started" => true })
    end

    # Clears previous sync stats (useful at start of sync).
    #
    # @param sync [Sync] The sync record to update
    def clear_sync_stats(sync)
      return unless sync.respond_to?(:sync_stats)

      sync.update!(sync_stats: { "cleared_at" => Time.current.iso8601 })
    end

    # Collects statistics about entries that were skipped during sync.
    # Skipped entries are those protected from sync overwrites (user-modified,
    # import-locked, excluded, or converted to different types).
    #
    # @param sync [Sync] The sync record to update
    # @param skipped_entries [Array<Hash>] Array of skipped entry info with :id, :name, :reason, :account_name
    # @return [Hash] The skip stats that were collected
    def collect_skip_stats(sync, skipped_entries:)
      return {} unless sync.respond_to?(:sync_stats)
      return {} if skipped_entries.blank?

      # Group by reason for summary breakdown
      by_reason = skipped_entries.group_by { |e| e[:reason] }

      skip_stats = {
        "tx_skipped" => skipped_entries.size,
        "skip_summary" => by_reason.transform_values(&:size),
        "skip_details" => skipped_entries.first(20).map do |e|
          {
            "entry_id" => e[:id].to_s,
            "name" => e[:name],
            "reason" => e[:reason],
            "account_name" => e[:account_name]
          }
        end
      }

      merge_sync_stats(sync, skip_stats)
      skip_stats
    end

    private

      # Merges new stats into the existing sync_stats hash.
      #
      # @param sync [Sync] The sync record to update
      # @param new_stats [Hash] The new stats to merge
      def merge_sync_stats(sync, new_stats)
        return unless sync.respond_to?(:sync_stats)

        existing = sync.sync_stats || {}
        sync.update!(sync_stats: existing.merge(new_stats))
      rescue => e
        Rails.logger.warn("SyncStats::Collector#merge_sync_stats failed: #{e.class} - #{e.message}")
      end
  end
end
