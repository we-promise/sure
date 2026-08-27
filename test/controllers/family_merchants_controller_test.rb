require "test_helper"

class FamilyMerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
  end

  test "index" do
    get family_merchants_path
    assert_response :success
  end

  test "new" do
    get new_family_merchant_path
    assert_response :success
  end

  test "should create merchant" do
    assert_difference("FamilyMerchant.count") do
      post family_merchants_url, params: { family_merchant: { name: "new merchant", color: "#000000" } }
    end

    assert_redirected_to family_merchants_path
    created_merchant = FamilyMerchant.find_by(name: "new merchant")
    assert_equal "#000000", created_merchant.color
  end

  test "should update merchant" do
    patch family_merchant_url(@merchant), params: { family_merchant: { name: "new name", color: "#000000" } }
    assert_redirected_to family_merchants_path
    assert_equal "#000000", @merchant.reload.color
  end

  test "should destroy merchant" do
    assert_difference("FamilyMerchant.count", -1) do
      delete family_merchant_url(@merchant)
    end

    assert_redirected_to family_merchants_path
  end

  test "should create merchant as json" do
    assert_difference("FamilyMerchant.count") do
      post family_merchants_url(format: :json), params: { family_merchant: { name: "Quick Merchant" } }
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "Quick Merchant", response_body["name"]
    assert response_body["id"].present?
    assert_includes response_body["html"], "data-merchant-select-target=\"option\""
  end

  test "should return json validation errors for duplicate merchant name" do
    assert_no_difference("FamilyMerchant.count") do
      post family_merchants_url(format: :json), params: { family_merchant: { name: @merchant.name } }
    end

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["errors"].present?
  end

  test "renders html (not turbo-stream) for duplicate merchant name when submitted like a Turbo form" do
    assert_no_difference("FamilyMerchant.count") do
      post family_merchants_url,
        params: { family_merchant: { name: @merchant.name } },
        headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }
    end

    assert_response :unprocessable_entity
    assert_equal "text/html", response.media_type
    assert_includes response.body, @merchant.name
  end

  test "enhance enqueues job and redirects" do
    assert_enqueued_with(job: EnhanceProviderMerchantsJob) do
      post enhance_family_merchants_path
    end

    assert_redirected_to family_merchants_path
  end
end
