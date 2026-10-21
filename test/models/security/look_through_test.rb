require "test_helper"

# A fund's asset class says nothing about what it holds: a bond ETF and an
# equity ETF are the same wrapper around different things. Looking through the
# fund to its constituents is what answers that. These tests cover what the
# stored rows mean, which is the rule every reader of them depends on.
class Security::LookThroughTest < ActiveSupport::TestCase
  setup do
    @security = securities(:aapl)
  end

  # --------------------------------------------------- what the weights mean

  # The figures deliberately sum to 99.4, not 100. A fund's reported holdings
  # routinely fall short by a little -- cash, rounding, securities lending -- and
  # a list this close to 100 is the whole fund (`WHOLE_FUND_FROM`), so dividing
  # it by 100 would silently under-report every constituent. Dividing by the
  # actual sum is what makes the expansion add up.
  test "weights are normalised against their actual sum, not against 100" do
    hold("MSFT", 50.0)
    hold("NVDA", 30.0)
    hold("TSLA", 19.4)

    weights = @security.look_through_weights

    assert_in_delta 1.0, weights.values.sum.to_f, 0.000001,
                    "the expansion does not add up to the whole fund"
    assert_in_delta 50.0 / 99.4, weights["MSFT"].to_f, 0.000001
    assert_in_delta 19.4 / 99.4, weights["TSLA"].to_f, 0.000001

    naive = 50.0 / 100
    assert_not_in_delta naive, weights["MSFT"].to_f, 0.000001,
                        "dividing by 100 would give the same answer, so this asserts nothing"
  end

  # A list well short of 100 is a partial one (a "top holdings" feed that stops
  # at 80). It is divided by 100, so each name keeps its reported share and the
  # rest stays unlisted rather than being spread over the names that were listed.
  test "a list well short of 100 is divided by 100, not by its own sum" do
    hold("MSFT", 50.0)
    hold("NVDA", 30.0)

    weights = @security.look_through_weights

    assert_in_delta 0.5, weights["MSFT"].to_f, 0.000001, "50 of the fund is half of it, not 50/80"
    assert_in_delta 0.3, weights["NVDA"].to_f, 0.000001
    assert_in_delta 0.8, weights.values.sum.to_f, 0.000001, "the listed names were scaled up to the whole fund"
  end

  test "a security with no constituents looks through to nothing" do
    assert_empty @security.look_through_weights
  end

  test "a fund whose weights are all missing looks through to nothing" do
    hold("MSFT", nil)

    assert_empty @security.look_through_weights
  end

  # A fund whose every reported weight is 0 is the only way the sum can be zero
  # with rows present, so it is the only case that reaches the divide. Without
  # the guard this raises ZeroDivisionError rather than declining to answer.
  test "a fund whose weights are all zero declines to answer rather than dividing" do
    hold("MSFT", 0)
    hold("NVDA", 0)

    result = nil
    assert_nothing_raised { result = @security.look_through_weights }
    assert_empty result
  end

  # ------------------------------------------- the whole-fund threshold, 99

  # Both sides of the boundary, through the shared rule, so the unlisted
  # remainder is under test as well as the listed fractions.
  test "a list summing to exactly 99 is the whole fund, with nothing unlisted" do
    shares = Security::Constituent.fund_shares([ row("MSFT", "60"), row("NVDA", "39") ])

    assert_equal 0, shares.unlisted
    assert_equal BigDecimal("60") / BigDecimal("99"), shares.listed["MSFT"]
    assert_in_delta 1.0, shares.listed.values.sum.to_f, 0.000001
  end

  test "a list summing to 98.99 is partial, and leaves 1.01 percent of the fund unlisted" do
    shares = Security::Constituent.fund_shares([ row("MSFT", "60"), row("NVDA", "38.99") ])

    assert_equal BigDecimal("0.0101"), shares.unlisted
    assert_equal BigDecimal("0.6"), shares.listed["MSFT"]
    assert_equal BigDecimal("0.3899"), shares.listed["NVDA"]
  end

  # Overlapping share classes or leverage can push a list past 100. It is
  # divided by its own sum, so the names are scaled down to the whole fund and
  # nothing is reported unlisted.
  test "a list over 100 is divided by its own sum" do
    shares = Security::Constituent.fund_shares([ row("MSFT", "60"), row("NVDA", "50") ])

    assert_equal 0, shares.unlisted
    assert_equal BigDecimal("60") / BigDecimal("110"), shares.listed["MSFT"]
  end

  test "rows without a weight are left out of the split" do
    shares = Security::Constituent.fund_shares([ row("MSFT", "50"), row("CASH", nil), row("NVDA", "30") ])

    assert_equal [ "MSFT", "NVDA" ], shares.listed.keys
    assert_equal BigDecimal("0.2"), shares.unlisted
  end

  # ------------------------------------------------------------ the rows

  # EODHD reports a rounded `Assets_%` and returns 0 for a position too small to
  # round up to 0.01. A validation refusing zero would make that one row fail,
  # and with it whatever stores the rest of the fund alongside it.
  test "a negligible holding reported as zero is a valid row, and a negative weight is not" do
    assert @security.constituents.new(ticker: "TINY", weight: 0).valid?
    assert_not @security.constituents.new(ticker: "SHORT", weight: -0.01).valid?
  end

  test "a negligible holding reported as zero does not disturb the rest of the fund" do
    hold("MSFT", 60.0)
    hold("TINY", 0)
    hold("NVDA", 40.0)

    assert_in_delta 0.6, @security.look_through_weights["MSFT"].to_f, 0.000001
    assert_equal 0, @security.look_through_weights["TINY"]
  end

  test "a fund lists each ticker once, and another fund may list the same ticker" do
    hold("MSFT", 10)

    assert_not @security.constituents.new(ticker: "MSFT", weight: 5).valid?
    assert securities(:msft).constituents.new(ticker: "MSFT", weight: 5).valid?
    assert_not @security.constituents.new(ticker: nil, weight: 5).valid?
  end

  # Securities are deleted by `Security.destroy_all` in the demo data cleaner
  # and by `securities:` rake tasks. The foreign key would refuse those deletes
  # if the fund's rows were left behind.
  test "destroying a security removes its constituents" do
    fund = Security.create!(ticker: "FUND", name: "Fund")
    fund.constituents.create!(ticker: "MSFT", weight: 60)
    fund.constituents.create!(ticker: "NVDA", weight: 40)
    securities(:msft).constituents.create!(ticker: "AAPL", weight: 10)

    assert_difference -> { Security::Constituent.count }, -2 do
      fund.destroy!
    end
  end

  private
    def hold(ticker, weight)
      @security.constituents.create!(ticker: ticker, name: ticker, weight: weight)
    end

    def row(ticker, weight)
      Security::Constituent.new(ticker: ticker, weight: weight && BigDecimal(weight))
    end
end
