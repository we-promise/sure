# frozen_string_literal: true

# View helpers for SimpleFin UI rendering
module SimplefinItemsHelper
  # Builds a compact tooltip text summarizing sync errors from a stats hash.
  # The stats structure comes from SimplefinItem::Importer and Sync records.
  # Returns nil when there is nothing meaningful to display.
  #
  # Example structure:
  #   {
  #     "total_errors" => 3,
  #     "errors" => [ { "name" => "Chase", "message" => "Timeout" }, ... ],
  #     "error_buckets" => { "auth" => 1, "api" => 2 }
  #   }
  def simplefin_error_tooltip(stats)
    return nil unless stats.is_a?(Hash)

    total_errors = stats["total_errors"].to_i
    return nil if total_errors.zero?

    sample = Array(stats["errors"]).map do |e|
      name = (e[:name] || e["name"]).to_s
      msg  = (e[:message] || e["message"]).to_s
      name.present? ? "#{name}: #{msg}" : msg
    end.compact.first(2).join(" • ")

    buckets = stats["error_buckets"] || {}
    bucket_text = if buckets.present?
      buckets.map { |k, v| "#{k}: #{v}" }.join(", ")
    end

    parts = [ "Errors: ", total_errors.to_s ]
    parts << " (#{bucket_text})" if bucket_text.present?
    parts << " — #{sample}" if sample.present?
    parts.join
  end
end
