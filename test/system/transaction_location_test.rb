require "application_system_test_case"

class TransactionLocationTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "setting a location on a transaction via search and drag-confirm" do
    entry = create_transaction(account: accounts(:depository), name: "Travelodge Malaga", amount: 100)

    Geocoding::NominatimClient.any_instance.stubs(:search).returns(
      [ Geocoding::NominatimClient::Result.new(lat: 41.3851, lng: 2.1734, display_name: "Barcelona, Spain") ]
    )

    visit transaction_path(entry)
    find("summary", text: /#{I18n.t("transactions.show.details")}/i).click

    fill_in "Search a place...", with: "Barcelona"
    assert_text "Barcelona, Spain"
    find("li", text: "Barcelona, Spain").click

    # requestSubmit() fires a Turbo Stream PATCH; Capybara's default_max_wait_time
    # (5s, set in ApplicationSystemTestCase) already covers the round trip, so
    # asserting on the resulting DOM state needs no custom wait of its own.
    assert_selector "[data-location-picker-target='display']:not(.hidden)"

    entry.reload
    assert_equal "Barcelona, Spain", entry.location_name
    assert_equal 41.3851, entry.location_lat.to_f
    assert_equal 2.1734, entry.location_lng.to_f
  end
end
