# Income by the security that paid it. A dividend names a security only when
# the provider recorded one, so whatever cannot be named is kept as
# `unattributed` (total - attributed) and the table adds up to `total`.
# Built from plain values (Portfolio::DailyReturns#income_by_security and
# Portfolio::Income#total), so it survives a cached Portfolio::Performance#income.
class Portfolio::IncomeBySecurity
  Row = Data.define(:security, :amount)

  attr_reader :amounts, :total

  # Keyed by the id as Security's uuid type casts it, as the row lookup reads it
  # back, so two spellings of one id are summed. An id that is not a uuid has
  # no key and stays in #unattributed.
  def initialize(amounts:, total:)
    @amounts = (amounts || {}).each_with_object({}) do |(id, amount), keyed|
      key = self.class.canonical_id(id)
      keyed[key] = keyed.fetch(key, BigDecimal(0)) + amount if key
    end
    @total = total
  end

  def self.canonical_id(id)
    Security.type_for_attribute(:id).cast(id.to_s)
  end

  # Largest first, then by ticker and id for a stable order. An id with no
  # Security is not a row; it is part of #unattributed.
  def rows
    @rows ||= securities.filter_map { |security|
      Row.new(security: security, amount: amounts.fetch(security.id.to_s))
    }.sort_by { |row| [ -row.amount, row.security.ticker.to_s, row.security.id.to_s ] }
  end

  # Takes a Security or its id; zero when nothing is attributed to it. A
  # Security is read by its id: its to_s is not the id.
  def amount_for(security_or_id)
    id = security_or_id.respond_to?(:id) ? security_or_id.id : security_or_id
    amounts.fetch(self.class.canonical_id(id), BigDecimal(0))
  end

  def attributed
    @attributed ||= rows.sum(BigDecimal(0), &:amount)
  end

  # Income with no security recorded, or one this install does not have.
  def unattributed
    @unattributed ||= total - attributed
  end

  def any?
    rows.any? || !unattributed.zero?
  end

  private
    def securities
      return [] if amounts.empty?

      # Securities are global and the ids come from this family's own
      # entries; a per-family securities table would need a scope here.
      Security.where(id: amounts.keys).to_a
    end
end
