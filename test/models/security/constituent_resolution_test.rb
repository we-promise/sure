require "test_helper"

# A constituent is stored as a bare ticker, and `securities` allows one ticker
# on several exchanges. Picking one of several rows would file the fund's slice
# under whichever listing the database returned, so the total would stay right
# while the classification changed from run to run. These pin the rule that
# replaces the guess.
class Security::ConstituentResolutionTest < ActiveSupport::TestCase
  setup do
    @london = Security.create!(ticker: "DUAL", exchange_operating_mic: "XLON", name: "Dual London")
    @new_york = Security.create!(ticker: "DUAL", exchange_operating_mic: "XNYS", name: "Dual New York")
  end

  test "a constituent with one listing resolves to it" do
    resolution = Security::Constituent.resolve_tickers([ "AAPL" ])

    assert_equal securities(:aapl), resolution.securities["AAPL"]
    assert_empty resolution.ambiguous
  end

  # The household's own position is the best evidence of which listing a fund
  # means.
  test "a colliding ticker resolves to the listing the family holds" do
    resolution = Security::Constituent.resolve_tickers([ "DUAL" ], held_security_ids: [ @new_york.id ])

    assert_equal @new_york, resolution.securities["DUAL"]
    assert_empty resolution.ambiguous
  end

  # No held position to decide it, so the honest answer is no answer, and the
  # ticker is named so a reader can say so.
  test "a colliding ticker the family does not hold resolves to nothing and is named" do
    resolution = Security::Constituent.resolve_tickers([ "DUAL" ], held_security_ids: [ securities(:aapl).id ])

    assert_nil resolution.securities.fetch("DUAL")
    assert_equal Set["DUAL"], resolution.ambiguous
  end

  # Owning the London and the New York line says nothing about which one the
  # fund reported. Picking either would be the same guess in a smaller set.
  test "holding both candidates does not resolve the ambiguity" do
    resolution = Security::Constituent.resolve_tickers([ "DUAL" ], held_security_ids: [ @london.id, @new_york.id ])

    assert_nil resolution.securities.fetch("DUAL")
    assert_equal Set["DUAL"], resolution.ambiguous
  end

  # A ticker never seen is not the same as one seen twice, and only the second
  # is worth telling the user about.
  test "a constituent with no security row resolves to nothing and is not ambiguous" do
    resolution = Security::Constituent.resolve_tickers([ "NOSUCH" ])

    assert resolution.securities.key?("NOSUCH")
    assert_nil resolution.securities["NOSUCH"]
    assert_empty resolution.ambiguous
  end

  # Providers report tickers in whatever case they like; `securities` stores
  # them upcased. A fund reporting both "dual" and "DUAL" is one ticker.
  test "tickers are matched without regard to case and reported once" do
    resolution = Security::Constituent.resolve_tickers([ "aapl", "dual", "DUAL" ])

    assert_equal [ "AAPL", "DUAL" ], resolution.securities.keys.sort
    assert_equal securities(:aapl), resolution.securities["AAPL"]
    assert_equal Set["DUAL"], resolution.ambiguous
  end

  # A reader resolving a whole portfolio's constituents pays one query, not one
  # per fund or per ticker.
  test "every ticker is resolved in one query" do
    assert_queries_count(1) do
      Security::Constituent.resolve_tickers([ "AAPL", "MSFT", "DUAL", "NOSUCH" ], held_security_ids: [ @london.id ])
    end
  end

  test "no tickers make no query" do
    assert_queries_count(0) do
      resolution = Security::Constituent.resolve_tickers([])
      assert_empty resolution.securities
      assert_empty resolution.ambiguous
    end
  end
end
