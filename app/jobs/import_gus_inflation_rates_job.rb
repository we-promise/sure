class ImportGusInflationRatesJob < ApplicationJob
  queue_as :scheduled

  def perform(start_year: Date.current.year - 1, end_year: Date.current.year, force: false)
    return unless Setting.gus_inflation_import_enabled_effective

    imported_count = GusInflationRate.import_range!(start_year:, end_year:, force:)

    Setting.gus_inflation_last_import_at = Time.current
    Setting.gus_inflation_last_import_count = imported_count
    Setting.gus_inflation_last_import_range = "#{start_year}-#{end_year}"
    Setting.gus_inflation_last_import_error = nil
  rescue StandardError => error
    Setting.gus_inflation_last_import_error = error.message
    raise
  end
end
