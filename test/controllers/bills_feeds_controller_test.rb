require "test_helper"

class BillsFeedsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    # The feed is preview-gated on the member the token names.
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family.recurring_transactions.destroy_all
    create_bill(name: "Rent", amount: 2150)
  end

  test "a member token serves the feed without a session" do
    get bills_feed_url(token: @family.bills_feed_token_for(@user))

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

  # The stored family secret is the revocation root, not a credential: putting
  # it in a URL would hand every member the whole family's obligations.
  test "the raw family secret is not itself a feed token" do
    get bills_feed_url(token: @family.bills_feed_token!)

    assert_response :not_found
  end

  # Sharing is per account, so the feed has to honor it: a member who cannot
  # reach an account in the app must not receive its bills by calendar.
  test "a member's feed carries only the bills that member can reach" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    # The investment account is the admin's and was never shared.
    create_bill(name: "Private Brokerage Fee", amount: 95, account: accounts(:investment))
    create_bill(name: "Gym", amount: 30, account: nil)

    get bills_feed_url(token: @family.bills_feed_token_for(member))

    assert_response :success
    assert_match "Gym", response.body
    assert_no_match(/Private Brokerage Fee/, response.body)

    get bills_feed_url(token: @family.bills_feed_token_for(@user))

    assert_match "Gym", response.body
    assert_match "Private Brokerage Fee", response.body
  end

  test "resetting the token revokes every member URL and freshly minted ones work" do
    old_token = @family.bills_feed_token_for(@user)
    @family.reset_bills_feed_token!

    get bills_feed_url(token: old_token)
    assert_response :not_found

    get bills_feed_url(token: @family.reload.bills_feed_token_for(@user))
    assert_response :success
    assert_match "BEGIN:VCALENDAR", response.body
  end

  # The feed is sessionless, so the preview gate has to travel with the token:
  # a retained calendar URL must die the moment its member opts out, not only
  # after an explicit token reset.
  test "a retained URL stops working when the member opts out of preview" do
    token = @family.bills_feed_token_for(@user)

    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    get bills_feed_url(token: token)
    assert_response :not_found

    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    get bills_feed_url(token: token)
    assert_response :success
  end

  test "the feed honors the family recurring switch" do
    token = @family.bills_feed_token_for(@user)
    @family.update!(recurring_transactions_disabled: true)

    get bills_feed_url(token: token)

    assert_response :not_found
  end

  test "the family secret generates lazily exactly once" do
    assert_nil @family.bills_feed_token

    first = @family.bills_feed_token!
    second = @family.bills_feed_token!

    assert first.present?
    assert_equal first, second
  end

  private

    def create_bill(name:, amount:, account: accounts(:depository))
      @family.recurring_transactions.create!(
        account: account,
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
