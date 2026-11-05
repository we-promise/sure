require "test_helper"

class Family::SimilarMatcherTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = Family.create!(name: "Similar family")
    @account = @family.accounts.create!(name: "Similar", balance: 0, currency: "USD", accountable: Depository.new)
    @streaming = @family.categories.create!(name: "Streaming")
    @groceries = @family.categories.create!(name: "Groceries")
    @netflix = @family.merchants.create!(name: "Netflix")
  end

  def transaction(name, **attributes)
    create_transaction(account: @account, name: name, **attributes).transaction
  end

  def matcher(pool, threshold: 0.8, min_neighbours: 2)
    Family::SimilarMatcher.new(pool, threshold: threshold, min_neighbours: min_neighbours, common_share: 0.2)
  end

  test "matches the same description written differently, ignoring numbers and codes" do
    pool = [ transaction("NETFLIX.COM 8812 REF 4K22X9"), transaction("Safeway Groceries 0042") ]

    neighbours = matcher(pool).neighbours(transaction("Netflix com 1203 REF 7Q91Z3"))

    assert_equal [ pool.first ], neighbours.map(&:first)
    assert_in_delta 1.0, neighbours.first.last, 0.001
  end

  test "agrees only when enough neighbours have one value and none another" do
    pool = [ transaction("Netflix com", category: @streaming, merchant: @netflix),
             transaction("NETFLIX.COM", category: @streaming),
             transaction("Netflix.com", merchant: @netflix) ]
    query = transaction("NETFLIX COM")

    assert_equal @streaming.id, matcher(pool).agreed(query, :category_id)
    assert_equal @netflix.id, matcher(pool).agreed(query, :merchant_id)
    assert_nil matcher(pool, min_neighbours: 3).agreed(query, :category_id)

    pool << transaction("Netflix com", category: @groceries)
    assert_nil matcher(pool).agreed(query, :category_id)
  end

  test "a different shop isn't a neighbour" do
    pool = [ transaction("Safeway Groceries"), transaction("Trader Joes Groceries") ]

    assert_equal [], matcher(pool).neighbours(transaction("Whole Foods Groceries")).map(&:first)
  end

  test "never matches the transaction itself" do
    own = transaction("Netflix com", category: @streaming)

    assert_equal [], matcher([ own ], min_neighbours: 1).neighbours(own)
  end
end
