class GusInflationRate < ApplicationRecord
  PERIOD_TO_MONTH = {
    247 => 1,
    248 => 2,
    249 => 3,
    250 => 4,
    251 => 5,
    252 => 6,
    253 => 7,
    254 => 8,
    255 => 9,
    256 => 10,
    257 => 11,
    258 => 12
  }.freeze

  validates :year, :month, :rate_yoy, presence: true
  validates :month, inclusion: { in: 1..12 }
  validates :year, uniqueness: { scope: :month }

  class << self
    def for_date(date:, lag_months: 0)
      target_date = date.beginning_of_month - lag_months.to_i.months
      find_by(year: target_date.year, month: target_date.month)
    end

    def yoy_index_for(date:, lag_months: 0)
      for_date(date:, lag_months:)&.rate_yoy
    end

    def import_year!(year:, force: false)
      return 0 if !force && year_complete?(year)

      response = provider.fetch_cpi_yoy_for_year(year: year)
      unless response.success?
        return 0 if not_found_error?(response.error) || rate_limited_error?(response.error)
        raise response.error.is_a?(Exception) ? response.error : RuntimeError.new(response.error.to_s)
      end

      rows = response.data
      return 0 if rows.blank?

      imported = 0

      rows.each do |row|
        month = PERIOD_TO_MONTH[row[:period_id].to_i]
        next if month.blank?

        value = row[:value]
        next if value.blank?
        rate_yoy = value.to_d
        next if rate_yoy.zero?

        existing = find_by(year: year.to_i, month: month)
        next if !force && existing.present? && existing.rate_yoy == rate_yoy

        upsert({ year: year.to_i, month: month, rate_yoy: rate_yoy, source: "sdp" },
               unique_by: :index_gus_inflation_rates_on_year_and_month)
        imported += 1
      end

      imported
    end

    def import_range!(start_year:, end_year:, force: false)
      from = start_year.to_i
      to = end_year.to_i
      return 0 if from > to

      (from..to).sum { |year| import_year!(year: year, force: force) }
    end

    private
      def provider
        # Don't memoize; allow credential changes without restart.
        Provider::GusSdp.new(api_key: api_key, cpi_indicator_id: cpi_indicator_id)
      end

      def api_key
        ENV["GUS_SDP_API_KEY"].presence || Setting.gus_sdp_api_key
      end

      def cpi_indicator_id
        indicator_id = ENV["GUS_SDP_CPI_INDICATOR_ID"].presence
        indicator_id.presence || Provider::GusSdp::DEFAULT_CPI_INDICATOR_ID
      end

      def not_found_error?(error)
        return false if error.blank?

        message = error.message.to_s
        message.include?("status 404") || message.include?("404")
      end

      def rate_limited_error?(error)
        return false if error.blank?

        message = error.message.to_s
        message.include?("status 429") || message.include?("429")
      end

      def year_complete?(year)
        where(year: year.to_i).count >= 12
      end

      def latest_before_or_on(target_date)
        where("make_date(year, month, 1) <= ?", target_date)
          .order(year: :desc, month: :desc)
          .first
      end
  end
end
