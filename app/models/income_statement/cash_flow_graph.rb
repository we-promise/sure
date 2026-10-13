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
      sankey: IncomeStatement::Sankey.new(@statement, period: @period).as_json
    }
  end
end
