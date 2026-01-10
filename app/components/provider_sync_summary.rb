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
  attr_reader :stats, :provider_item, :institutions_count

  # @param stats [Hash] The sync statistics hash from sync.sync_stats
  # @param provider_item [Object] The provider item (must respond to last_synced_at)
  # @param institutions_count [Integer, nil] Optional count of connected institutions
  def initialize(stats:, provider_item:, institutions_count: nil)
    @stats = stats || {}
    @provider_item = provider_item
    @institutions_count = institutions_count
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
