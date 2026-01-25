# frozen_string_literal: true

# Reusable sync summary component for provider items.
#
# This component displays sync statistics in a collapsible panel that can be used
# by any provider (SimpleFIN, Plaid, Lunchflow, etc.) to show their sync results.
#
# @example Basic usage
#   <%= render ProviderSyncSummary.new(
#     stats: @sync_stats,
#     provider_item: @plaid_item
#   ) %>
#
# @example With custom institution count
#   <%= render ProviderSyncSummary.new(
#     stats: @sync_stats,
#     provider_item: @simplefin_item,
#     institutions_count: @simplefin_item.connected_institutions.size
#   ) %>
#
class ProviderSyncSummary < ViewComponent::Base
  attr_reader :stats, :provider_item, :institutions_count, :activities_pending

  # @param stats [Hash] The sync statistics hash from sync.sync_stats
  # @param provider_item [Object] The provider item (must respond to last_synced_at)
  # @param institutions_count [Integer, nil] Optional count of connected institutions
  # @param activities_pending [Boolean] Whether activities are still being fetched in background
  def initialize(stats:, provider_item:, institutions_count: nil, activities_pending: false)
    @stats = stats || {}
    @provider_item = provider_item
    @institutions_count = institutions_count
    @activities_pending = activities_pending
  end

  def activities_pending?
    @activities_pending
  end

  def render?
    stats.present?
  end

  # Account statistics
  def total_accounts
    stats["total_accounts"].to_i
  end

  def linked_accounts
    stats["linked_accounts"].to_i
  end

  def unlinked_accounts
    stats["unlinked_accounts"].to_i
  end

  # Transaction statistics
  def tx_seen
    stats["tx_seen"].to_i
  end

  def tx_imported
    stats["tx_imported"].to_i
  end

  def tx_updated
    stats["tx_updated"].to_i
  end

  def tx_skipped
    stats["tx_skipped"].to_i
  end

  def has_transaction_stats?
    stats.key?("tx_seen") || stats.key?("tx_imported") || stats.key?("tx_updated")
  end

  # Skip statistics (protected entries not overwritten)
  def has_skipped_entries?
    tx_skipped > 0
  end

  def skip_summary
    stats["skip_summary"] || {}
  end

  def skip_details
    stats["skip_details"] || []
  end

  # Holdings statistics
  def holdings_found
    stats["holdings_found"].to_i
  end

  def holdings_processed
    stats["holdings_processed"].to_i
  end

  def has_holdings_stats?
    stats.key?("holdings_found") || stats.key?("holdings_processed")
  end

  def holdings_label_key
    stats.key?("holdings_processed") ? "processed" : "found"
  end

  def holdings_count
    stats.key?("holdings_processed") ? holdings_processed : holdings_found
  end

  # Trades statistics (investment activities like buy/sell)
  def trades_imported
    stats["trades_imported"].to_i
  end

  def trades_skipped
    stats["trades_skipped"].to_i
  end

  def has_trades_stats?
    stats.key?("trades_imported") || stats.key?("trades_skipped")
  end

  # Returns the CSS color class for a data quality detail severity
  # @param severity [String] The severity level ("warning", "error", or other)
  # @return [String] The Tailwind CSS class for the color
  def severity_color_class(severity)
    case severity
    when "warning" then "text-warning"
    when "error" then "text-destructive"
    else "text-secondary"
    end
  end

  # Health statistics
  def rate_limited?
    stats["rate_limited"].present? || stats["rate_limited_at"].present?
  end

  def rate_limited_ago
    return nil unless stats["rate_limited_at"].present?

    begin
      helpers.time_ago_in_words(Time.parse(stats["rate_limited_at"]))
    rescue StandardError
      nil
    end
  end

  def total_errors
    stats["total_errors"].to_i
  end

  def import_started?
    stats["import_started"].present?
  end

  def has_errors?
    total_errors > 0
  end

  def error_details
    stats["errors"] || []
  end

  def error_buckets
    stats["error_buckets"] || {}
  end

  # Stale pending transactions (auto-excluded)
  def stale_pending_excluded
    stats["stale_pending_excluded"].to_i
  end

  def has_stale_pending?
    stale_pending_excluded > 0
  end

  def stale_pending_details
    stats["stale_pending_details"] || []
  end

  # Stale unmatched pending (need manual review - couldn't be automatically matched)
  def stale_unmatched_pending
    stats["stale_unmatched_pending"].to_i
  end

  def has_stale_unmatched_pending?
    stale_unmatched_pending > 0
  end

  def stale_unmatched_details
    stats["stale_unmatched_details"] || []
  end

  # Pending→posted reconciliation stats
  def pending_reconciled
    stats["pending_reconciled"].to_i
  end

  def has_pending_reconciled?
    pending_reconciled > 0
  end

  def pending_reconciled_details
    stats["pending_reconciled_details"] || []
  end

  # Duplicate suggestions needing user review
  def duplicate_suggestions_created
    stats["duplicate_suggestions_created"].to_i
  end

  def has_duplicate_suggestions_created?
    duplicate_suggestions_created > 0
  end

  def duplicate_suggestions_details
    stats["duplicate_suggestions_details"] || []
  end

  # Data quality / warnings
  def data_warnings
    stats["data_warnings"].to_i
  end

  def notices
    stats["notices"].to_i
  end

  def data_quality_details
    stats["data_quality_details"] || []
  end

  def has_data_quality_issues?
    data_warnings > 0 || notices > 0 || data_quality_details.any?
  end

  # Last sync time
  def last_synced_at
    provider_item.last_synced_at
  end

  def last_synced_ago
    return nil unless last_synced_at

    helpers.time_ago_in_words(last_synced_at)
  end
end
