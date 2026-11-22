require "test_helper"

class MapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get map_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "renders for users with preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get map_url

    assert_response :success
  end

  test "only returns located entries belonging to the current family" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    account = accounts(:depository)
    located = account.entries.create!(
      name: "Travelodge Malaga", date: Date.current, amount: 100, currency: "EUR",
      location_lat: 36.72, location_lng: -4.42, location_name: "Malaga, Spain",
      entryable: Transaction.new
    )
    unlocated = account.entries.create!(
      name: "Groceries", date: Date.current, amount: 20, currency: "EUR",
      entryable: Transaction.new
    )

    get map_url

    assert_response :success
    assert_match located.id, response.body
    assert_no_match unlocated.id, response.body
  end

  test "account_id param filters located entries to that account" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    account = accounts(:depository)
    other_account = accounts(:credit_card)
    in_account = account.entries.create!(
      name: "Travelodge Malaga", date: Date.current, amount: 100, currency: "EUR",
      location_lat: 36.72, location_lng: -4.42, location_name: "Malaga, Spain",
      entryable: Transaction.new
    )
    in_other_account = other_account.entries.create!(
      name: "Hotel Barcelona", date: Date.current, amount: 150, currency: "EUR",
      location_lat: 41.38, location_lng: 2.17, location_name: "Barcelona, Spain",
      entryable: Transaction.new
    )

    get map_url(account_id: account.id)

    assert_match in_account.id, response.body
    assert_no_match in_other_account.id, response.body
  end
end
