require "test_helper"

class OpenBankingIoItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
  end

  def create_item(name: "OBIO Test")
    OpenBankingIoItem.create!(
      family: @family, name: name,
      api_base_url: "https://open-banking.io", api_key: "k", private_key: "p"
    )
  end

  def credentials_json(overrides = {})
    {
      "apiBaseUrl" => "https://staging.open-banking.io",
      "apiKey" => "paste-api-key",
      "encryptionKey" => { "privateKey" => "paste-private-key" }
    }.deep_merge(overrides).to_json
  end

  # The pasted bundle carries the API key and the PKCS#8 key that decrypts every envelope.
  # Rails filters by parameter NAME, and "credentials_json" matches none of the stock
  # substrings -- without an explicit entry the whole bundle lands in the request log (and,
  # via Sentry's active_support_logger breadcrumbs, in Sentry).
  test "credentials_json is filtered from request logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("open_banking_io_item" => { "credentials_json" => "SECRET-KEY-MATERIAL" })

    assert_equal "[FILTERED]", filtered["open_banking_io_item"]["credentials_json"]
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

  # Fix 3: valid JSON of the wrong SHAPE (null, an array, or a non-object
  # encryptionKey) must be rejected as invalid credentials, not raise a
  # NoMethodError/TypeError that surfaces as a 500.
  test "create rejects valid-but-wrong-shape credentials json without a 500" do
    [ "null", "[1,2,3]", { "apiBaseUrl" => "https://open-banking.io", "apiKey" => "k", "encryptionKey" => "oops" }.to_json ].each do |body|
      assert_no_difference "OpenBankingIoItem.count", "body #{body.inspect} should not create an item" do
        post open_banking_io_items_url, params: {
          open_banking_io_item: { name: "WrongShape", credentials_json: body }
        }, headers: { "Turbo-Frame" => "open_banking_io-providers-panel" }
      end

      assert_response :unprocessable_entity, "body #{body.inspect} should be a validation error, not a 500"
    end
  end

  # Fix 9: if unlinking an account fails, destroy must NOT schedule the connection
  # for deletion (which would orphan Holding/AccountProvider rows) — it must
  # surface an error and leave the item intact.
  test "destroy does not delete the item when unlink_all! reports a failure" do
    item = @family.open_banking_io_items.create!(
      name: "To Delete",
      api_base_url: "https://open-banking.io",
      api_key: "k",
      private_key: "pk"
    )

    OpenBankingIoItem.any_instance.stubs(:unlink_all!).returns([
      { provider_account_id: 1, name: "Everyday", provider_link_ids: [ 1 ], error: "could not unlink" }
    ])

    assert_no_enqueued_jobs only: DestroyJob do
      delete open_banking_io_item_url(item)
    end

    assert_redirected_to settings_providers_path
    assert_not item.reload.scheduled_for_deletion
  end

  # === AUTHORIZATION ===

  test "every mutating action requires an admin" do
    sign_in users(:family_member)
    item = create_item

    post open_banking_io_items_url, params: { open_banking_io_item: { credentials_json: credentials_json } }
    assert_response :redirect

    patch open_banking_io_item_url(item), params: { open_banking_io_item: { name: "Renamed" } }
    assert_response :redirect

    post sync_open_banking_io_item_url(item)
    assert_response :redirect

    get setup_accounts_open_banking_io_item_url(item)
    assert_response :redirect

    post link_accounts_open_banking_io_items_url, params: { open_banking_io_item_id: item.id }
    assert_response :redirect

    delete open_banking_io_item_url(item)
    assert_response :redirect

    assert OpenBankingIoItem.exists?(item.id), "a non-admin must not be able to delete a connection"
    assert_equal "OBIO Test", item.reload.name
  end

  # === CROSS-FAMILY ISOLATION ===

  test "cannot reach another family's connection" do
    other_item = OpenBankingIoItem.create!(
      family: families(:empty), name: "Someone else's bank",
      api_base_url: "https://open-banking.io", api_key: "k", private_key: "p"
    )

    get select_accounts_open_banking_io_items_url(open_banking_io_item_id: other_item.id)
    assert_response :not_found

    post link_accounts_open_banking_io_items_url,
         params: { open_banking_io_item_id: other_item.id, account_ids: [ "x" ] }
    assert_response :not_found
  end

  test "cannot link another family's account" do
    item = create_item
    provider_account = item.open_banking_io_accounts.create!(
      account_id: "acc-1", name: "Everyday", currency: "EUR"
    )
    other_account = families(:empty).accounts.create!(
      name: "Not mine", balance: 1, currency: "EUR", accountable: Depository.new
    )

    post link_existing_account_open_banking_io_items_url, params: {
      open_banking_io_item_id: item.id,
      account_id: other_account.id,
      open_banking_io_account_id: provider_account.id
    }

    assert_response :not_found
    assert_nil provider_account.reload.account_provider
  end

  # === LINKING FLOW ===

  test "link_accounts creates one account per selection and links it" do
    item = create_item
    first = item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR", current_balance: 250)
    second = item.open_banking_io_accounts.create!(account_id: "a2", name: "Savings", currency: "EUR", current_balance: 900)

    assert_difference "Account.count", 2 do
      post link_accounts_open_banking_io_items_url, params: {
        open_banking_io_item_id: item.id,
        accountable_type: "Depository",
        account_ids: [ first.id, second.id ]
      }
    end

    assert_redirected_to accounts_path
    assert_equal 250, first.reload.account.balance
    assert_equal "Savings", second.reload.account.name
  end

  test "link_accounts stores a credit card balance as a positive magnitude" do
    item = create_item
    card = item.open_banking_io_accounts.create!(account_id: "c1", name: "Card", currency: "EUR", current_balance: -430)

    post link_accounts_open_banking_io_items_url, params: {
      open_banking_io_item_id: item.id, accountable_type: "CreditCard", account_ids: [ card.id ]
    }

    assert_equal 430, card.reload.account.balance
  end

  test "link_accounts rejects an unsupported accountable type" do
    item = create_item
    provider_account = item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR")

    assert_no_difference "Account.count" do
      post link_accounts_open_banking_io_items_url, params: {
        open_banking_io_item_id: item.id, accountable_type: "Crypto", account_ids: [ provider_account.id ]
      }
    end

    assert_redirected_to new_account_path
  end

  test "link_accounts skips a provider account that is already linked" do
    item = create_item
    provider_account = item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR")
    existing = @family.accounts.create!(name: "Already", balance: 5, currency: "EUR", accountable: Depository.new)
    AccountProvider.create!(account: existing, provider: provider_account)

    assert_no_difference "Account.count" do
      post link_accounts_open_banking_io_items_url, params: {
        open_banking_io_item_id: item.id, accountable_type: "Depository", account_ids: [ provider_account.id ]
      }
    end
  end

  test "link_existing_account flashes rather than 404ing on a stale provider account id" do
    item = create_item
    account = @family.accounts.create!(name: "Mine", balance: 1, currency: "EUR", accountable: Depository.new)

    post link_existing_account_open_banking_io_items_url, params: {
      open_banking_io_item_id: item.id,
      account_id: account.id,
      open_banking_io_account_id: SecureRandom.uuid
    }

    assert_redirected_to accounts_path
    assert_equal I18n.t("open_banking_io_items.link_existing_account.open_banking_io_account_not_found"), flash[:alert]
  end

  test "sync tells the user when the connection is already syncing" do
    item = create_item
    OpenBankingIoItem.any_instance.stubs(:syncing?).returns(true)

    post sync_open_banking_io_item_url(item)

    assert_equal I18n.t("open_banking_io_items.sync.already_syncing"), flash[:alert]
  end

  # === OPEN REDIRECT GUARD ===
  # 27 lines of security-critical string parsing that had no test at all.

  test "return_to only accepts a relative path that resolves to a real route" do
    item = create_item
    provider_account = item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR")

    hostile = [
      "//evil.com",
      "/\\evil.com",
      "%2f%2fevil.com",
      "%5c%5cevil.com",
      "https://evil.com",
      "http://evil.com/accounts",
      "/accounts\\@evil.com",
      "/accounts\u0000",
      "not-a-path"
    ]

    hostile.each_with_index do |return_to, i|
      obio = item.open_banking_io_accounts.create!(account_id: "hostile-#{i}", name: "A#{i}", currency: "EUR")
      post link_accounts_open_banking_io_items_url, params: {
        open_banking_io_item_id: item.id, accountable_type: "Depository",
        account_ids: [ obio.id ], return_to: return_to
      }
      assert_redirected_to accounts_path, "return_to #{return_to.inspect} must not be honoured"
    end

    # ...and a genuine in-app path still is.
    post link_accounts_open_banking_io_items_url, params: {
      open_banking_io_item_id: item.id, accountable_type: "Depository",
      account_ids: [ provider_account.id ], return_to: "/accounts"
    }
    assert_redirected_to "/accounts"
  end

  # These pickers render INTO a turbo-frame. A redirect answers with a full page that has no
  # matching frame, which Turbo discards -- the modal just closes with no explanation. The
  # unconfigured case must therefore render a frame, not redirect.
  test "select_accounts without a connection renders setup instructions inside the modal frame" do
    assert_equal 0, @family.open_banking_io_items.count

    get select_accounts_open_banking_io_items_url(accountable_type: "Depository")

    assert_response :success
    assert_match(/<turbo-frame[^>]+id="modal"/, response.body)
    assert_match I18n.t("open_banking_io_items.setup_required.title"), response.body
    assert_match settings_providers_path, response.body
  end

  test "select_existing_account without a connection renders the same frame" do
    account = @family.accounts.create!(name: "Mine", balance: 1, currency: "EUR", accountable: Depository.new)

    get select_existing_account_open_banking_io_items_url(account_id: account.id)

    assert_response :success
    assert_match(/<turbo-frame[^>]+id="modal"/, response.body)
    assert_match I18n.t("open_banking_io_items.setup_required.title"), response.body
  end

  test "select_accounts with no id uses the family's configured connection" do
    item = create_item
    item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR")
    OpenBankingIoItem.any_instance.stubs(:refresh_accounts_from_provider!).returns(nil)

    get select_accounts_open_banking_io_items_url(accountable_type: "Depository")

    assert_response :success
  end

  # === TURBO FRAME CONTRACTS ===
  # Every one of these is the same bug class: a response that does not contain the frame
  # the request came from is discarded by Turbo, and the user sees nothing happen at all.

  # The picker form submits to _top, and select_accounts answers `render layout: false` --
  # a bare frame with no <html>, CSS or JS, so redirecting back to it lands the user on a
  # blank white page with the flash lost.
  test "link_accounts errors redirect somewhere that renders standalone" do
    item = create_item
    provider_account = item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR")

    post link_accounts_open_banking_io_items_url,
         params: { open_banking_io_item_id: item.id, accountable_type: "Depository", account_ids: [] }
    assert_redirected_to new_account_path

    post link_accounts_open_banking_io_items_url,
         params: { open_banking_io_item_id: item.id, accountable_type: "Depository",
                   account_ids: [ provider_account.id ], return_to: "/accounts" }
    assert_response :redirect
    assert_not_includes response.location, "select_accounts",
                        "never bounce back to a layout-less picker"
  end

  # The connect drawer wraps the panel in a frame with target="_top", so no Turbo-Frame
  # header is sent. A 422 redirect has an empty body and Turbo renders nothing -- pasting a
  # malformed credentials.json did literally nothing.
  test "a bad credentials paste outside a frame navigates and shows the error" do
    assert_no_difference "OpenBankingIoItem.count" do
      post open_banking_io_items_url, params: {
        open_banking_io_item: { name: "Broken", credentials_json: "{not json" }
      }
    end

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert flash[:alert].present?, "the user must be told why it failed"
  end

  # setup_accounts is behind require_admin!, which redirects to a page with no modal frame.
  # A member would get a dead button, so the link is not rendered for them at all.
  test "the setup-accounts link is only offered to admins" do
    item = create_item
    item.open_banking_io_accounts.create!(account_id: "a1", name: "Unlinked", currency: "EUR")

    get accounts_url
    assert_match setup_accounts_open_banking_io_item_path(item), response.body

    sign_in users(:family_member)
    get accounts_url
    assert_no_match setup_accounts_open_banking_io_item_path(item), response.body
  end
end
