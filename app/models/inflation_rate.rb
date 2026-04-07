class InflationRate < ApplicationRecord
  validates :source, :year, :month, :rate_yoy, presence: true
  validates :month, inclusion: { in: 1..12 }
  validates :year, uniqueness: { scope: %i[source month] }

  class << self
    def for_date(source:, date:, lag_months: 0)
      target_date = date.beginning_of_month - lag_months.to_i.months
      find_by(source: source.to_s, year: target_date.year, month: target_date.month)
    end

    def import_year!(source:, provider:, year:, force: false)
      source_key = source.to_s
      target_year = year.to_i
      return 0 if !force && year_complete?(source: source_key, year: target_year)

      response = provider.fetch_cpi_yoy_for_year(year: target_year)
      unless response.success?
        return 0 if not_found_error?(response.error)
        raise response.error.is_a?(Exception) ? response.error : RuntimeError.new(response.error.to_s)
      end

      rows = response.data
      return 0 if rows.blank?

      imported = 0

      rows.each do |row|
        month = row[:month].to_i
        next unless month.between?(1, 12)

        raw_rate_yoy = row[:rate_yoy]
        # Skip rows with no rate data. Zero is valid (0% YoY change) and must not be dropped.
        next if raw_rate_yoy.blank?
        rate_yoy = raw_rate_yoy.to_d

        existing = find_by(source: source_key, year: target_year, month: month)
        next if !force && existing.present? && existing.rate_yoy == rate_yoy

        upsert(
          { source: source_key, year: target_year, month: month, rate_yoy: rate_yoy },
          unique_by: :index_inflation_rates_on_source_and_year_and_month
        )
        imported += 1
      end

      imported
    end

    private
      def year_complete?(source:, year:)
        where(source: source, year: year).count >= 12
      end

      def not_found_error?(error)
        return false if error.blank?
        return true if error.respond_to?(:response) && error.response&.dig(:status) == 404

        message = error.message.to_s
        message.include?("status 404") || message.match?(/\b404\b/)
      end
  end
end
