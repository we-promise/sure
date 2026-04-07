class ImportInflationRatesJob < ApplicationJob
  queue_as :scheduled

  def perform(start_year: Date.current.year - 1, end_year: Date.current.year, force: false, providers: nil)
    return unless Setting.gus_inflation_import_enabled_effective

    imported_by_provider = InflationRateImporter.new(
      start_year:,
      end_year:,
      force:,
      providers:
    ).import_all

    Setting.gus_inflation_last_import_at = Time.current
    Setting.gus_inflation_last_import_count = imported_by_provider.values.sum
    Setting.gus_inflation_last_import_range = "#{start_year}-#{end_year}"
    Setting.inflation_last_import_details = imported_by_provider.stringify_keys.to_json
    Setting.gus_inflation_last_import_error = nil
  rescue StandardError => error
    Setting.gus_inflation_last_import_error = error.message
    raise
  end
end
