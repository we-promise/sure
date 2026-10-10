require "test_helper"

class UI::Account::ActivityFeedTest < ViewComponent::TestCase
  test "not filtered with no params" do
    assert_not build_feed(q: {}).filtered?
  end

  test "not filtered with a blank search" do
    assert_not build_feed(q: { "search" => "" }).filtered?
  end

  test "not filtered when only the amount operator default is submitted" do
    # The operator select always submits ("equal" by default), even on an
    # untouched blur-submit. Alone it must not count as an active filter,
    # otherwise every search focus-out hides the balance column.
    assert_not build_feed(q: { "search" => "", "amount_operator" => "equal" }).filtered?
  end

  test "filtered when an amount value is present with its operator" do
    assert build_feed(q: { "amount" => "5", "amount_operator" => "equal" }).filtered?
  end

  test "filtered with a search term" do
    assert build_feed(q: { "search" => "coffee" }).filtered?
  end

  test "filtered with a selected checkbox collection, ignoring blank entries" do
    assert_not build_feed(q: { "status" => [ "" ] }).filtered?
    assert build_feed(q: { "status" => [ "", "confirmed" ] }).filtered?
  end

  private
    def build_feed(q:)
      feed_data = Account::ActivityFeedData.new(accounts(:depository), [])
      UI::Account::ActivityFeed.new(feed_data: feed_data, pagy: nil, q: q)
    end
end
