require "test_helper"

class Security::SearchTest < ActiveSupport::TestCase
  setup do
    @listed = Security.create!(ticker: "SRCHA", name: "Listed", exchange_operating_mic: "XNAS", kind: "standard")
    @offline = Security.create!(ticker: "SRCHB", name: "Offline", exchange_operating_mic: "XLON", kind: "standard", offline: true)
    @cash = Security.create!(ticker: "SRCHC", name: "Cash", kind: "cash")
    @scope = Security.where(id: [ @listed.id, @offline.id, @cash.id ])
  end

  test "with no filters returns the scope it is given" do
    assert_equal @scope.to_a.sort_by(&:id), search.securities_scope.to_a.sort_by(&:id)
  end

  test "matches the ticker whatever its case" do
    assert_equal [ @listed ], search(ticker: "srcha").securities_scope.to_a
  end

  test "matches the exchange operating MIC whatever its case" do
    assert_equal [ @offline ], search(exchange_operating_mic: "xlon").securities_scope.to_a
  end

  test "filters by kind" do
    assert_equal [ @cash ], search(kind: "cash").securities_scope.to_a
  end

  test "filters by offline status, false included" do
    assert_equal [ @offline ], search(offline: true).securities_scope.to_a
    assert_equal [ @listed, @cash ].sort_by(&:id), search(offline: false).securities_scope.to_a.sort_by(&:id)
  end

  test "never reaches securities outside the scope it is given" do
    outside = Security.create!(ticker: "SRCHA", name: "Elsewhere", exchange_operating_mic: "XNYS")

    assert_not_includes search(ticker: "SRCHA").securities_scope, outside
  end

  private
    def search(**filters)
      Security::Search.new(@scope, filters:)
    end
end
