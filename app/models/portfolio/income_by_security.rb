# Income by the security it came from, with the income that cannot be
# attributed kept as a bucket of its own.
#
# The reason the bucket exists: the daily rows are scope-wide, and a
# Transaction-shaped dividend names a security only when the provider recorded
# one (Transaction#activity_security_id). A table of just the attributed rows
# would sum to less than the monthly total beside it -- one period, two
# totals. So `unattributed` is `total - attributed`, and the table
# adds up to `total` by construction rather than by two queries agreeing.
#
# `total` is whatever the daily rows report for the same period
# (Portfolio::Income#total), and `amounts` is
# Portfolio::DailyReturns#income_by_security, which reads the same entries
# through the same fragments. Both are plain values, so this survives being
# built from a cached Portfolio::Performance#income.
class Portfolio::IncomeBySecurity
  Row = Data.define(:security, :amount)

  attr_reader :amounts, :total

  # `amounts` is { "security-uuid" => BigDecimal }; `total` the period's income.
  def initialize(amounts:, total:)
    @amounts = (amounts || {}).transform_keys(&:to_s)
    @total = total
  end

  # One row per security this install knows, largest first and then by ticker
  # so the order does not depend on the database. An id with no Security behind
  # it cannot be named, so it is not a row; it is part of #unattributed.
  def rows
    @rows ||= securities.filter_map { |security|
      Row.new(security: security, amount: amounts.fetch(security.id.to_s))
    }.sort_by { |row| [ -row.amount, row.security.ticker.to_s, row.security.id.to_s ] }
  end

  # The amount attributed to one security, or zero. Takes a Security or its id,
  # so a caller holding either does not have to normalise first. A Security is
  # read by its id: its to_s is not the id, and the key would match nothing.
  def amount_for(security_or_id)
    id = security_or_id.respond_to?(:id) ? security_or_id.id : security_or_id
    amounts.fetch(id.to_s, BigDecimal(0))
  end

  def attributed
    @attributed ||= rows.sum(BigDecimal(0), &:amount)
  end

  # Everything the total holds that no row accounts for: income with no security
  # recorded, and income whose recorded security this install does not have.
  def unattributed
    @unattributed ||= total - attributed
  end

  def any?
    rows.any? || !unattributed.zero?
  end

  private
    def securities
      return [] if amounts.empty?

      # Ids that are not UUIDs are dropped by the cast and simply find nothing.
      Security.where(id: amounts.keys).to_a
    end
end
