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

  test "should create merchant with a manually entered iban" do
    post family_merchants_url, params: { family_merchant: { name: "Landlord", iban: "de89 3704 0044 0532 0130 00" } }

    created_merchant = FamilyMerchant.find_by(name: "Landlord")
    assert_equal "DE89370400440532013000", created_merchant.iban # pipelock:ignore IBAN
  end

  test "should update merchant iban" do
    patch family_merchant_url(@merchant), params: { family_merchant: { name: @merchant.name, iban: "AT611904300234573201" } } # pipelock:ignore IBAN
    assert_equal "AT611904300234573201", @merchant.reload.iban # pipelock:ignore IBAN
  end

  test "updating only website on a provider merchant updates it directly without converting to a family merchant" do
    provider_merchant = ProviderMerchant.create!(name: "Provider Payee", source: "enable_banking")
    transactions(:one).update!(merchant: provider_merchant)

    patch family_merchant_url(provider_merchant), params: { provider_merchant: { website_url: "https://example.com" } }

    assert_redirected_to family_merchants_path
    assert_equal "https://example.com", provider_merchant.reload.website_url
    assert_instance_of ProviderMerchant, Merchant.find(provider_merchant.id)
  end

  test "updating iban on a provider merchant converts it to a family merchant instead of mutating the shared record" do
    # A ProviderMerchant is shared across every family it's assigned to; iban
    # drives cross-family merchant-identity matching (unlike website_url),
    # so an edit must not leak into other families' future transactions.
    provider_merchant = ProviderMerchant.create!(name: "Provider Payee", source: "enable_banking")
    transactions(:one).update!(merchant: provider_merchant)

    assert_difference "FamilyMerchant.count", 1 do
      patch family_merchant_url(provider_merchant), params: { provider_merchant: { iban: "AT611904300234573201" } } # pipelock:ignore IBAN
    end

    assert_redirected_to family_merchants_path
    assert_nil provider_merchant.reload.iban, "the shared ProviderMerchant must be untouched"

    converted = @user.family.merchants.find_by(name: "Provider Payee")
    assert_instance_of FamilyMerchant, converted
    assert_equal "AT611904300234573201", converted.iban # pipelock:ignore IBAN
    assert_equal converted.id, transactions(:one).reload.merchant_id
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
