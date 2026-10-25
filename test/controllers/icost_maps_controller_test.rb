require "test_helper"

class IcostMapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
    @batch = IcostImport.prepare!(family: @user.family, user: @user, filename: "map.csv", bytes: CSV.generate { |csv|
      csv << Icost::Normalizer::HEADERS
      2.times do
        csv << Icost::Normalizer::HEADERS.map { |key| { "日期" => "2026/01/02", "类型" => "支出", "金额" => "-12", "货币" => "USD", "账户1" => "Synthetic wallet", "一级分类" => "Synthetic category", "位置" => "Synthetic museum" }[key] }
      end
    })
  end

  test "map keeps unresolved places visible without contacting a map service" do
    get icost_map_path
    assert_response :success
    assert_select "[data-icost-place]", text: /Synthetic museum/
    assert_select "[data-icost-map-target='record']", count: 0
    assert_select "[data-action='icost-map#load']", count: 1
  end

  test "map uses main application navigation beside transactions on desktop and mobile" do
    get icost_map_path
    assert_response :success
    assert_select "[data-controller~='app-layout']", count: 1
    assert_select "nav a[href=?][aria-current='page']", icost_map_path, count: 2, text: I18n.t("icost_maps.nav_label")
    assert_select "nav a[href=?]", transactions_path, count: 2
    assert_select "h1", text: I18n.t("icost_maps.title")
    assert_select "#settings-nav-container", count: 0
    get transactions_path
    assert_select "nav a[href=?]", icost_map_path, count: 2
  end

  test "confirming a location maps all same-name rows without changing source fields or money" do
    before = @batch.records.map { |record| record.attributes.slice("raw_fields", "latitude", "longitude", "status") }
    assert_no_difference "Entry.count" do
      patch icost_map_path, params: { icost_location: { place: "Synthetic museum", latitude: "51.5", longitude: "-0.1" } }
    end
    assert_redirected_to icost_map_path
    assert_equal before, @batch.records.reload.map { |record| record.attributes.slice("raw_fields", "latitude", "longitude", "status") }
    assert @batch.records.all? { |record| record.map_coordinates == [ 51.5, -0.1 ] }
    get icost_map_path
    assert_select "[data-icost-map-target='record']", count: 2
  end

  test "another user cannot read or resolve owned source locations" do
    sign_in users(:family_member)
    get icost_map_path
    assert_response :success
    refute_includes response.body, "Synthetic museum"
    patch icost_map_path, params: { icost_location: { place: "Synthetic museum", latitude: "51.5", longitude: "-0.1" } }
    assert @batch.records.all? { |record| record.resolution.empty? }
  end

  test "street and site matches are visibly approximate until a precise place is confirmed" do
    record = @batch.records.first
    record.update!(resolution: { "location" => { "latitude" => 51.5, "longitude" => -0.1, "accuracy" => "street", "source" => "nominatim_name_match" } })
    @batch.records.last.update!(resolution: { "location" => { "latitude" => 51.51, "longitude" => -0.1, "accuracy" => "area", "source" => "nominatim_name_match" } })
    get icost_map_path
    assert_response :success
    assert_includes response.body, I18n.t("icost_maps.approximate_help", count: 2)
    assert_select "[data-icost-location-accuracy]", text: I18n.t("icost_maps.approximate_location")
    patch icost_map_path, params: { icost_location: { place: "Synthetic museum", latitude: "51.5001", longitude: "-0.1001" } }
    refute record.reload.approximate_map_location?
    assert_equal "user_confirmed_place", record.resolution.dig("location", "source")
  end

  test "invalid coordinates are rejected" do
    patch icost_map_path, params: { icost_location: { place: "Synthetic museum", latitude: "NaN", longitude: "181" } }
    assert_redirected_to icost_map_path
    assert flash[:alert].present?
    assert @batch.records.all? { |record| record.resolution.empty? }
  end

  test "overlapping source archives do not duplicate map markers" do
    Balance::Materializer.any_instance.stubs(:materialize_balances)
    later = IcostImport.prepare!(family: @user.family, user: @user, filename: "map-again.csv", bytes: @batch.source_bytes.gsub("\n", "\r\n"))
    later.process!(user: @user)
    IcostRecord.locate_place!(user: @user, place: "Synthetic museum", latitude: "51.5", longitude: "-0.1")
    get icost_map_path
    assert_response :success
    assert_select "[data-icost-map-target='record']", count: 2
  end
end
