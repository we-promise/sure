# Converts persisted BasisTradeSnapshot rows into the JSON payload consumed by
# the Basis page chart. Date filtering, serialization and KPI rollups happen
# here on the server; the browser is only responsible for recomputing the
# displayed line as leg toggles change.
class BasisTradeSeriesBuilder
  # Legs are stored in integer subunits and surfaced to the chart as plain
  # decimals divided by this factor so the client can sum them directly.
  CENTS_PER_UNIT = 1_000.0

  def initialize(family:, start_date: nil, end_date: nil)
    @family = family
    @start_date = start_date
    @end_date = end_date
  end

  def payload
    {
      currency: currency,
      range: range,
      totals: totals,
      points: points
    }
  end

  private
    attr_reader :family, :start_date, :end_date

    def snapshots
      @snapshots ||= begin
        scope = BasisTradeSnapshot.for_family(family).chronological
        scope = scope.where(recorded_at: start_date.beginning_of_day..) if start_date
        scope = scope.where(recorded_at: ..end_date.end_of_day) if end_date
        scope.to_a
      end
    end

    def currency
      snapshots.last&.currency || family.primary_currency_code
    end

    def range
      {
        start_date: start_date&.iso8601,
        end_date: end_date&.iso8601
      }
    end

    def totals
      latest = snapshots.last
      return { spot: 0.0, short: 0.0, funding: 0.0, rewards: 0.0, combined: 0.0 } if latest.nil?

      leg_values(latest)
    end

    def points
      snapshots.map do |snapshot|
        date = snapshot.recorded_at.to_date
        leg_values(snapshot).merge(
          date: date.iso8601,
          date_formatted: I18n.l(date, format: :long)
        )
      end
    end

    def leg_values(snapshot)
      spot = to_decimal(snapshot.spot_leg_cents)
      short = to_decimal(snapshot.short_leg_cents)
      funding = to_decimal(snapshot.funding_accrued_cents)
      rewards = to_decimal(snapshot.rewards_accrued_cents)

      {
        spot: spot,
        short: short,
        funding: funding,
        rewards: rewards,
        combined: (spot + short + funding + rewards).round(2)
      }
    end

    def to_decimal(cents)
      (cents / CENTS_PER_UNIT).round(2)
    end
end
