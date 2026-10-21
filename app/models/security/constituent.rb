# One line of a fund's holdings, as the provider reports it.
#
# `weight` is the provider's own percentage of fund assets and is stored
# unnormalised on purpose -- see the migration. `.fund_shares` is what turns a
# fund's rows into shares of the fund, and it is the one rule every reader of
# the rows goes through, so two readers cannot answer differently for the same
# fund.
class Security::Constituent < ApplicationRecord
  # A list summing to at least this many percentage points is the whole fund.
  # Reported holdings rarely sum to exactly 100 -- rounding, cash, securities
  # lending -- and that drift is normalised against the actual sum, so the
  # listed names carry the fund between them. Below it the list is partial (a
  # "top holdings" feed stopping at 80): it is divided by 100, so each name
  # keeps its reported share and the rest is reported as unlisted rather than
  # spread over the names that were listed. A list over 100 (overlapping share
  # classes, leverage) is also divided by its own sum, which scales the names
  # down to the whole fund.
  WHOLE_FUND_FROM = BigDecimal("99")
  PERCENT = BigDecimal("100")

  # `listed` maps each ticker to its fraction of the fund; `unlisted` is the
  # fraction no row names, zero for a whole-fund list.
  FundShares = Data.define(:listed, :unlisted)
  NO_SHARES = FundShares.new(listed: {}.freeze, unlisted: 0)

  belongs_to :security

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :security_id }
  # Zero is allowed, and this is not a cosmetic boundary: EODHD reports a
  # rounded `Assets_%` and returns 0 for a position too small to round up to
  # 0.01. Refusing zero would fail that one row, and with it the import that
  # stores the rest of the fund alongside it.
  validates :weight, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # Rows with a nil weight say nothing about the fund's split and are skipped.
  # A list whose weights sum to zero declines to answer rather than dividing
  # by it.
  def self.fund_shares(rows)
    weighted = rows.reject { |row| row.weight.nil? }
    total = weighted.sum(&:weight)
    return NO_SHARES unless total.positive?

    divisor = total >= WHOLE_FUND_FROM ? total : PERCENT
    listed = weighted.each_with_object({}) { |row, map| map[row.ticker] = row.weight / divisor }
    FundShares.new(listed: listed, unlisted: 1 - total / divisor)
  end

  # `securities` maps each upcased ticker to the row it means, or nil;
  # `ambiguous` holds the tickers that resolved to nil because several rows
  # matched and nothing said which one.
  Resolution = Data.define(:securities, :ambiguous)

  # Which `securities` row each constituent ticker means. A constituent is a
  # bare ticker, and `securities` allows one ticker on several exchanges, so
  # picking one of several matches would file the fund's slice under whichever
  # listing the database returned first, and the total would still add up.
  #
  # The rule: one match resolves. Several resolve only when the family holds
  # exactly one of them, because a household's own position is the best
  # evidence of which listing a fund means. Otherwise -- none held, or more
  # than one -- the ticker resolves to nil and is named in `ambiguous`, so a
  # reader can say so. A ticker with no row resolves to nil and is not
  # ambiguous. A reader should still count an unresolved constituent's value,
  # unclassified, rather than drop it.
  #
  # One query for every ticker given, so a reader can resolve a whole
  # portfolio's constituents at once rather than one fund at a time.
  def self.resolve_tickers(tickers, held_security_ids: [])
    wanted = tickers.map { |ticker| ticker.to_s.upcase }.uniq
    return Resolution.new(securities: {}, ambiguous: Set.new) if wanted.empty?

    candidates = Security.where("upper(ticker) IN (?)", wanted).group_by { |security| security.ticker.upcase }
    held = held_security_ids.to_set
    ambiguous = Set.new

    securities = wanted.index_with do |ticker|
      rows = candidates.fetch(ticker, [])
      next rows.first if rows.size <= 1

      held_rows = rows.select { |row| held.include?(row.id) }
      next held_rows.first if held_rows.one?

      ambiguous << ticker
      nil
    end

    Resolution.new(securities: securities, ambiguous: ambiguous)
  end
end
