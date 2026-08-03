require "test_helper"

class Holding::GapfillableTest < ActiveSupport::TestCase
  test "selects the latest snapshot on or before the date with a first-snapshot fallback" do
    snapshots = {
      [ 1, 1 ] => [
        [ Date.new(2025, 1, 1), false ],
        [ Date.new(2025, 1, 5), true ],
        [ Date.new(2025, 1, 5), false ],
        [ Date.new(2025, 1, 10), true ]
      ]
    }

    results = [
      Date.new(2024, 12, 31),
      Date.new(2025, 1, 1),
      Date.new(2025, 1, 6),
      Date.new(2025, 1, 10),
      Date.new(2025, 1, 11)
    ].map do |date|
      Holding.send(
        :provider_cash_equivalent_for,
        snapshots,
        account_id: 1,
        security_id: 1,
        date: date
      )
    end

    assert_equal [ false, false, false, true, true ], results
  end

  test "keeps snapshot lookups independent across account and security groups" do
    snapshots = {
      [ 1, 1 ] => [ [ Date.new(2025, 1, 1), false ], [ Date.new(2025, 1, 5), true ] ],
      [ 2, 1 ] => [ [ Date.new(2025, 1, 2), true ], [ Date.new(2025, 1, 6), false ] ]
    }

    results = [
      [ 1, 1, Date.new(2025, 1, 4) ],
      [ 2, 1, Date.new(2025, 1, 4) ],
      [ 1, 1, Date.new(2025, 1, 6) ],
      [ 2, 1, Date.new(2025, 1, 7) ]
    ].map do |account_id, security_id, date|
      Holding.send(
        :provider_cash_equivalent_for,
        snapshots,
        account_id: account_id,
        security_id: security_id,
        date: date
      )
    end

    assert_equal [ false, true, true, false ], results
  end
end
