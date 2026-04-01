class ImportGusInflationRatesJob < ApplicationJob
  queue_as :scheduled

  def perform(opts = {})
    return unless Setting.gus_inflation_import_enabled_effective

    opts = opts.to_h.symbolize_keys
    start_year = opts[:start_year].presence || 2006
    # Include current year so ongoing rate calculations have latest CPI.
    end_year = opts[:end_year].presence || Date.current.year
    force = opts[:force] || false

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
