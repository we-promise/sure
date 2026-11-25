require "test_helper"

class Security::Price::SearchTest < ActiveSupport::TestCase
  setup do
    @security = Security.create!(ticker: "PSRCH", name: "Priced")
    @other_security = Security.create!(ticker: "PSRCH2", name: "Also priced")

    @early = @security.prices.create!(date: Date.new(2024, 1, 10), price: 10, currency: "USD")
    @late = @security.prices.create!(date: Date.new(2024, 1, 20), price: 11, currency: "USD", provisional: true)
    @carried = @security.prices.create!(date: Date.new(2024, 1, 21), price: 11, currency: "USD", carried_forward: true)
    @eur = @other_security.prices.create!(date: Date.new(2024, 1, 20), price: 9, currency: "EUR")

    @scope = Security::Price.where(security_id: [ @security.id, @other_security.id ])
  end

  test "with no filters returns the scope it is given" do
    assert_equal @scope.to_a.sort_by(&:id), search.security_prices_scope.to_a.sort_by(&:id)
  end

  test "filters by security" do
    assert_equal [ @eur ], search(security_id: @other_security.id).security_prices_scope.to_a
  end

  test "matches the currency whatever its case" do
    assert_equal [ @eur ], search(currency: "eur").security_prices_scope.to_a
  end

  test "filters by an inclusive date range" do
    range = search(start_date: Date.new(2024, 1, 10), end_date: Date.new(2024, 1, 20), security_id: @security.id)

    assert_equal [ @early, @late ].sort_by(&:id), range.security_prices_scope.to_a.sort_by(&:id)
  end

  test "filters by provisional and carried_forward, false included" do
    assert_equal [ @late ], search(provisional: true).security_prices_scope.to_a
    assert_equal [ @carried ], search(carried_forward: true).security_prices_scope.to_a
    assert_equal [ @early, @late, @eur ].sort_by(&:id), search(carried_forward: false).security_prices_scope.to_a.sort_by(&:id)
    assert_not_includes search(provisional: false).security_prices_scope, @late
  end

  test "never reaches prices outside the scope it is given" do
    assert_empty Security::Price::Search.new(@scope.where(security_id: @security.id), filters: { security_id: @other_security.id }).security_prices_scope
  end

  private
    def search(**filters)
      Security::Price::Search.new(@scope, filters:)
    end
end
