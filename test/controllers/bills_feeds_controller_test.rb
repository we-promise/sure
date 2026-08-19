require "test_helper"

class BillsFeedsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @family.recurring_transactions.destroy_all
    create_bill(name: "Rent", amount: 2150)
  end

  test "a stored token serves the feed without a session" do
    get bills_feed_url(token: @family.bills_feed_token!)

    assert_response :success
    assert_match "BEGIN:VCALENDAR", response.body
    assert_match "Rent", response.body
  end

  test "an unknown token is not found" do
    get bills_feed_url(token: "nonsense")

    assert_response :not_found
  end

  # The old URLs carried a deterministic signed family id with no expiry and
  # no revocation. Breaking them is the point of the change: every URL minted
  # under the old scheme stops working.
  test "an old-style signed token no longer works" do
    signed = Rails.application.message_verifier("bills-ical-feed").generate(@family.id)

    get bills_feed_url(token: signed)

    assert_response :not_found
  end

  test "resetting the token revokes the old URL and the new one works" do
    old_token = @family.bills_feed_token!
    new_token = @family.reset_bills_feed_token!

    get bills_feed_url(token: old_token)
    assert_response :not_found

    get bills_feed_url(token: new_token)
    assert_response :success
    assert_match "BEGIN:VCALENDAR", response.body
  end

  test "the token generates lazily exactly once" do
    assert_nil @family.bills_feed_token

    first = @family.bills_feed_token!
    second = @family.bills_feed_token!

    assert first.present?
    assert_equal first, second
  end

  private

    def create_bill(name:, amount:)
      @family.recurring_transactions.create!(
        account: accounts(:depository),
        name: name,
        amount: amount,
        dedup_scope: amount.to_s,
        currency: "USD",
        expected_day_of_month: Date.current.day,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active"
      )
    end
end
