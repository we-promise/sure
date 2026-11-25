require "test_helper"

class LocationSearchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get location_searches_url(q: "Malaga")

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "returns JSON suggestions for a query" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    Geocoding::NominatimClient.any_instance.stubs(:search).with("Malaga").returns(
      [ Geocoding::NominatimClient::Result.new(lat: 36.72, lng: -4.42, display_name: "Malaga, Spain") ]
    )

    get location_searches_url(q: "Malaga"), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body.length
    assert_equal "Malaga, Spain", body.first["display_name"]
    assert_equal 36.72, body.first["lat"]
    assert_equal(-4.42, body.first["lng"])
  end

  test "returns an empty array for a blank query" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get location_searches_url(q: ""), as: :json

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "returns a service-unavailable status when Nominatim fails" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    Geocoding::NominatimClient.any_instance.stubs(:search).raises(Geocoding::NominatimClient::RequestFailed)

    get location_searches_url(q: "Malaga"), as: :json

    assert_response :service_unavailable
  end

  test "reverse returns JSON for coordinates" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    Geocoding::NominatimClient.any_instance.stubs(:reverse).with("41.3851", "2.1734").returns(
      Geocoding::NominatimClient::Result.new(lat: 41.3851, lng: 2.1734, display_name: "Barcelona, Spain")
    )

    get reverse_location_searches_url(lat: "41.3851", lng: "2.1734"), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Barcelona, Spain", body["display_name"]
    assert_equal 41.3851, body["lat"]
    assert_equal 2.1734, body["lng"]
  end

  test "reverse returns a service-unavailable status when Nominatim fails" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    Geocoding::NominatimClient.any_instance.stubs(:reverse).raises(Geocoding::NominatimClient::RequestFailed)

    get reverse_location_searches_url(lat: "41.3851", lng: "2.1734"), as: :json

    assert_response :service_unavailable
  end
end
