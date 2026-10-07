# Shared graph representation for the public API and session-authenticated web UI.
# Aggregation stays in Sankey; neither controller builds its own financial totals.
class IncomeStatement::CashFlowGraph
  def initialize(statement, period:, as_of: Date.current, time_zone: Time.zone.tzinfo.identifier)
    @statement, @period, @as_of, @time_zone = statement, period, as_of, time_zone
  end

  def as_json(*)
    {
      as_of: @as_of.iso8601, time_zone: @time_zone, currency: @statement.family.currency,
      period: { start_date: @period.start_date.iso8601, end_date: @period.end_date.iso8601 },
      sankey: IncomeStatement::Sankey.new(@statement, period: @period).as_json,
      # Same non-operating cash outflows CashFlow#as_json reports (see
      # Transaction::NON_OPERATING_KINDS): real money leaving an account, but
      # not consumption, so it's surfaced here too rather than only in the
      # public API's month-based CashFlow response.
      investment_contributions: decimal(@statement.investment_contribution_totals(period: @period).total)
    }
  end

  private
    def decimal(value)
      value.to_d.to_s("F")
    end
end
