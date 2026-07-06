require "test_helper"

class OpenBankingIoItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
  end

  def credentials_json(overrides = {})
    {
      "apiBaseUrl" => "https://staging.open-banking.io",
      "apiKey" => "paste-api-key",
      "encryptionKey" => { "privateKey" => "paste-private-key" }
    }.deep_merge(overrides).to_json
  end

  test "create parses the pasted credentials.json into the three stored fields" do
    assert_difference "OpenBankingIoItem.count", 1 do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "My Bank", credentials_json: credentials_json }
      }
    end

    item = @family.open_banking_io_items.order(:created_at).last
    assert_equal "My Bank", item.name
    assert_equal "https://staging.open-banking.io", item.api_base_url
    assert_equal "paste-api-key", item.api_key
    assert_equal "paste-private-key", item.private_key
    assert item.credentials_configured?
  end

  # Fix 3: SSRF guard. The apiBaseUrl the SDK client uses verbatim must be pinned
  # to open-banking.io (or a subdomain) over https; anything else is rejected at
  # create so a crafted credentials.json cannot point the client at an internal host.
  test "create rejects a credentials.json whose apiBaseUrl points at a non open-banking.io host" do
    json = credentials_json("apiBaseUrl" => "http://169.254.169.254/")

    assert_no_difference "OpenBankingIoItem.count" do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "SSRF", credentials_json: json }
      }, headers: { "Turbo-Frame" => "open_banking_io-providers-panel" }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects an http (non-https) open-banking.io apiBaseUrl" do
    json = credentials_json("apiBaseUrl" => "http://open-banking.io/")

    assert_no_difference "OpenBankingIoItem.count" do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "Insecure", credentials_json: json }
      }, headers: { "Turbo-Frame" => "open_banking_io-providers-panel" }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects a look-alike host that merely ends with the allowed domain" do
    json = credentials_json("apiBaseUrl" => "https://open-banking.io.evil.com/")

    assert_no_difference "OpenBankingIoItem.count" do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "Lookalike", credentials_json: json }
      }, headers: { "Turbo-Frame" => "open_banking_io-providers-panel" }
    end

    assert_response :unprocessable_entity
  end

  test "create accepts the real open-banking.io subdomain host" do
    assert_difference "OpenBankingIoItem.count", 1 do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "Real", credentials_json: credentials_json("apiBaseUrl" => "https://staging.open-banking.io") }
      }
    end
  end

  test "create accepts the apex open-banking.io host" do
    assert_difference "OpenBankingIoItem.count", 1 do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "Apex", credentials_json: credentials_json("apiBaseUrl" => "https://open-banking.io") }
      }
    end
  end

  test "create accepts the privateKeyPkcs8B64 alias for the private key" do
    json = { "apiBaseUrl" => "https://staging.open-banking.io", "apiKey" => "k", "encryptionKey" => { "privateKeyPkcs8B64" => "aliased-key" } }.to_json

    assert_difference "OpenBankingIoItem.count", 1 do
      post open_banking_io_items_url, params: { open_banking_io_item: { name: "Aliased", credentials_json: json } }
    end

    assert_equal "aliased-key", @family.open_banking_io_items.order(:created_at).last.private_key
  end

  test "create rejects malformed credentials json without creating an item" do
    assert_no_difference "OpenBankingIoItem.count" do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "Broken", credentials_json: "{not json" }
      }, headers: { "Turbo-Frame" => "open_banking_io-providers-panel" }
    end

    assert_response :unprocessable_entity
  end

  test "create rejects credentials json missing required fields" do
    json = { "apiBaseUrl" => "https://api.example.com" }.to_json

    assert_no_difference "OpenBankingIoItem.count" do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "Incomplete", credentials_json: json }
      }, headers: { "Turbo-Frame" => "open_banking_io-providers-panel" }
    end

    assert_response :unprocessable_entity
  end
end
