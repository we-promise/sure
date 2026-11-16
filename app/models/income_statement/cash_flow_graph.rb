# Shared graph representation for the public API and session-authenticated web UI.
# Aggregation stays in Sankey; neither controller builds its own financial totals.
class IncomeStatement::CashFlowGraph
  # group_by values: flows through one Cash Flow node by category (the default),
  # or through each account.
  GROUPINGS = {
    "category" => "IncomeStatement::Sankey",
    "account" => "IncomeStatement::AccountSankey"
  }.freeze

  def initialize(statement, period:, group_by: "category", as_of: Date.current, time_zone: Time.zone.tzinfo.identifier)
    raise ArgumentError, "unknown group_by: #{group_by}" unless GROUPINGS.key?(group_by)
    @statement, @period, @group_by, @as_of, @time_zone = statement, period, group_by, as_of, time_zone
  end

  def as_json(*)
    {
      as_of: @as_of.iso8601, time_zone: @time_zone, currency: @statement.family.currency,
      period: { start_date: @period.start_date.iso8601, end_date: @period.end_date.iso8601 },
      sankey: GROUPINGS.fetch(@group_by).constantize.new(@statement, period: @period).as_json
    }
  end
end
