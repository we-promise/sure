# frozen_string_literal: true

require "test_helper"
require "openssl"

class EnableBankingItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = @family.enable_banking_items.create!(
      name: "Test Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
    )
  end

  test "select_existing_account shows the last four IBAN digits to tell accounts apart" do
    checking = @item.enable_banking_accounts.create!(name: "Jane Doe", uid: "eb_checking", currency: "EUR", iban: "DE89370400440532013000") # pipelock:ignore IBAN
    savings = @item.enable_banking_accounts.create!(name: "Jane Doe", uid: "eb_savings", currency: "EUR", iban: "DE02120300000000202051") # pipelock:ignore IBAN

    get select_existing_account_enable_banking_items_url, params: { account_id: accounts(:depository).id }

    assert_response :success
    label_for = ->(eba) { css_select("label").find { |label| label.at_css("input[type=radio][value='#{eba.id}']") } }

    checking_label = label_for.call(checking)
    savings_label = label_for.call(savings)
    assert checking_label, "Expected a selectable entry for the checking account"
    assert savings_label, "Expected a selectable entry for the savings account"
    assert_match(/•\s*3000/, checking_label.text)
    assert_match(/•\s*2051/, savings_label.text)
    assert_no_match(/2051/, checking_label.text)
    assert_no_match(/3000/, savings_label.text)
    assert_no_match(/DE89370400440532013000/, @response.body, "Only the last four digits should be shown") # pipelock:ignore IBAN
  end

  test "select_bank lists banks for the requested country" do
    Provider::EnableBanking.any_instance.expects(:get_aspsps).with(country: "AT").returns(aspsps: [])

    get select_bank_enable_banking_item_url(@item, new_connection: true, country_code: "at")

    assert_response :success
  end

  test "select_bank ignores the requested country unless it is for a new connection" do
    Provider::EnableBanking.any_instance.expects(:get_aspsps).with(country: "DE").returns(aspsps: [])

    get select_bank_enable_banking_item_url(@item, country_code: "AT")

    assert_response :success
  end

  test "authorize keeps the item's country when it is not for a new connection" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(aspsps: [ { name: "Test Bank", country: "DE" } ])

    get select_bank_enable_banking_item_url(@item)

    assert_select "form[action='#{authorize_enable_banking_item_path(@item)}'] input[name=country_code][value=DE]"
  end

  test "select_bank falls back to the item's country for an unknown country" do
    Provider::EnableBanking.any_instance.expects(:get_aspsps).with(country: "DE").returns(aspsps: [])

    get select_bank_enable_banking_item_url(@item, country_code: "ZZ")

    assert_response :success
  end

  test "select_bank passes the requested country on to authorize" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(aspsps: [ { name: "Test Bank", country: "AT" } ])

    get select_bank_enable_banking_item_url(@item, new_connection: true, country_code: "AT")

    assert_select "form[action='#{authorize_enable_banking_item_path(@item)}'] input[name=country_code][value=AT]"
  end

  test "new_connection forwards the requested country to select_bank" do
    post new_connection_enable_banking_item_url(@item), params: { country_code: "AT" }

    assert_redirected_to select_bank_enable_banking_item_url(@item, new_connection: true, country_code: "AT")
  end

  test "authorize creates a new connection in the requested country" do
    stub_authorization_start

    assert_difference -> { @family.enable_banking_items.count }, 1 do
      post authorize_enable_banking_item_url(@item),
           params: { aspsp_name: "Test Bank", psu_type: "personal", new_connection: "true", country_code: "AT" }
    end

    created = @family.enable_banking_items.where.not(id: @item.id).order(:created_at).last
    assert_equal "AT", created.country_code
    assert_equal "DE", @item.reload.country_code
  end

  test "authorize keeps the item's country when the requested country is invalid" do
    stub_authorization_start

    post authorize_enable_banking_item_url(@item),
         params: { aspsp_name: "Test Bank", psu_type: "personal", new_connection: "true", country_code: "ZZ" }

    created = @family.enable_banking_items.where.not(id: @item.id).order(:created_at).last
    assert_equal "DE", created.country_code
  end

  test "select_bank exposes ASPSP BIC in the searchable data attribute" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "ING-DiBa AG",
          country: "DE",
          bic: "INGDDEFF",
          beta: false,
          psu_types: [ "personal" ],
          auth_methods: [ { approach: "REDIRECT" } ]
        }
      ]
    )

    get select_bank_enable_banking_item_url(@item)

    assert_response :success
    haystack = @response.body[/data-bank-search="([^"]*)"/, 1]
    assert haystack, "Expected list items to render a data-bank-search attribute the client filter reads from"
    assert_includes haystack, "ingddeff",
      "Expected the searchable data attribute to include the BIC so users can find banks by BIC code"
    assert_includes haystack, "ing-diba ag",
      "Expected the searchable data attribute to still include the bank name (existing name-search behavior)"
  end

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_enable_banking_item_url(@item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "enable_banking-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @item.reload.syncing?
  end

  # The Accounts page's Sync button posts here too, without the panel's source.
  test "sync from the Accounts page goes back to it" do
    post sync_enable_banking_item_url(@item),
         headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml", "Referer" => accounts_url }

    assert_redirected_to accounts_url
  end

  test "invalid create outside a frame redirects to the providers page with a 303" do
    assert_no_difference "EnableBankingItem.count" do
      post enable_banking_items_url, params: { enable_banking_item: { country_code: "", application_id: "" } }
    end

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert_match "can't be blank", flash[:alert]
  end

  test "invalid update outside a frame redirects to the providers page with a 303" do
    patch enable_banking_item_url(@item), params: { enable_banking_item: { country_code: "" } }

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert_match "can't be blank", flash[:alert]
    assert_equal "DE", @item.reload.country_code
  end

  # Redirecting back to Bank sync collapses the open connection row.
  test "update from the page re-renders the panel in place" do
    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { name: "Renamed Connection" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "enable_banking-providers-panel"
    assert_includes response.body, %(id="enable_banking-providers-panel")
    assert_equal "Renamed Connection", @item.reload.name
  end

  # The panel never sends a stored certificate back to the browser, so a save
  # that leaves the field blank must keep the one already stored.
  test "an update with a blank certificate keeps the stored one" do
    stored = @item.client_certificate

    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { name: "Renamed Connection", client_certificate: "" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "enable_banking-providers-panel"
    @item.reload
    assert_equal "Renamed Connection", @item.name
    assert_equal stored, @item.client_certificate
  end

  test "an update with a new certificate replaces the stored one" do
    replacement = OpenSSL::PKey::RSA.new(2048).to_pem

    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { client_certificate: replacement } },
          as: :turbo_stream

    assert_equal replacement, @item.reload.client_certificate
  end

  test "a create still requires a certificate" do
    @item.destroy!

    assert_no_difference "EnableBankingItem.count" do
      post enable_banking_items_url,
           params: { enable_banking_item: { country_code: "DE", application_id: "app", client_certificate: "" } },
           as: :turbo_stream
    end

    assert_response :unprocessable_entity
  end

  test "the panel does not send the stored certificate back to the browser" do
    get connect_form_settings_providers_url(provider_key: "enable_banking")

    assert_response :success
    assert_not_includes response.body, @item.client_certificate.lines.second.strip
    assert_select "textarea[name='enable_banking_item[client_certificate]']" do |fields|
      assert_equal "", fields.first.text.strip
    end
    assert_includes response.body, I18n.t("settings.providers.enable_banking_panel.keep_client_certificate_hint")
  end

  # An authenticated connection locks the credential fields, and a disabled
  # field is never submitted, so "leave blank to keep" does not apply there.
  test "the panel hides the keep-certificate hint while the credentials are locked" do
    @item.update!(session_id: "authenticated-session")

    get connect_form_settings_providers_url(provider_key: "enable_banking")

    assert_response :success
    assert_select "textarea[name='enable_banking_item[client_certificate]'][disabled]"
    assert_not_includes response.body, I18n.t("settings.providers.enable_banking_panel.keep_client_certificate_hint")
  end

  # The application id is the key id of every signed request, so the panel
  # treats it like the certificate: never echoed back, blank keeps it.
  test "the panel does not send the stored application id back to the browser" do
    @item.update_columns(application_id: "stored-app-id-#{SecureRandom.hex(8)}")

    get connect_form_settings_providers_url(provider_key: "enable_banking")

    assert_response :success
    assert_not_includes response.body, @item.application_id
    assert_select "input[name='enable_banking_item[application_id]']" do |fields|
      assert_nil fields.first["value"]
    end
  end

  test "the application id is filtered from logs" do
    parameter_filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered_params = parameter_filter.filter(
      enable_banking_item: { application_id: "stored-app-id", country_code: "DE" }
    )

    assert_equal "[FILTERED]", filtered_params.dig(:enable_banking_item, :application_id)
    assert_equal "DE", filtered_params.dig(:enable_banking_item, :country_code)
  end

  test "an update with a blank application id keeps the stored one" do
    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { name: "Renamed Connection", application_id: "" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "enable_banking-providers-panel"
    @item.reload
    assert_equal "Renamed Connection", @item.name
    assert_equal "test_app_id", @item.application_id
  end

  test "an update with a new application id replaces the stored one" do
    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { application_id: "replacement_app_id" } },
          as: :turbo_stream

    assert_equal "replacement_app_id", @item.reload.application_id
  end

  test "a create still requires an application id" do
    @item.destroy!

    assert_no_difference "EnableBankingItem.count" do
      post enable_banking_items_url,
           params: { enable_banking_item: { country_code: "DE", application_id: "", client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem } },
           as: :turbo_stream
    end

    assert_response :unprocessable_entity
  end

  test "invalid create from the page shows the error in the panel" do
    post enable_banking_items_url,
         params: { enable_banking_item: { country_code: "", application_id: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "enable_banking-providers-panel"
    assert_includes response.body, ERB::Util.html_escape("can't be blank")
  end

  test "authorize no longer blocks decoupled banks and proceeds to the hosted auth page" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "VR Bank in Holstein",
          country: "DE",
          psu_types: [ "personal" ],
          auth_methods: [ { name: "decoupled_app", approach: "DECOUPLED" } ]
        }
      ]
    )
    Provider::EnableBanking.any_instance.stubs(:start_authorization).returns(
      url: "https://api.enablebanking.com/auth/redirect/abc",
      authorization_id: "auth_1"
    )

    post authorize_enable_banking_item_url(@item),
         params: { aspsp_name: "VR Bank in Holstein", psu_type: "personal" }

    assert_redirected_to "https://api.enablebanking.com/auth/redirect/abc"
    assert_nil flash[:alert]
    assert_equal "DECOUPLED", @item.reload.aspsp_auth_approach
  end

  test "reauthorize without a stored bank redirects with an alert instead of raising" do
    assert_nil @item.aspsp_name

    assert_difference -> { DebugLogEntry.where(provider_key: "enable_banking", family: @family).count }, 1 do
      post reauthorize_enable_banking_item_url(@item)
    end

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("enable_banking_items.reauthorize.bank_required"), flash[:alert]
  end

  test "begin_authorization! raises a typed error when no bank is stored" do
    assert_raises(EnableBankingItem::BankNotSelectedError) do
      @item.begin_authorization!(redirect_url: "https://example.com/callback", state: "state")
    end
  end

  # Reconnect would only hit the same missing-bank error, so an expired item
  # without a stored bank offers the bank picker on the same item instead.
  test "the panel offers Connect bank instead of Reconnect for an expired item without a bank" do
    @item.update!(session_id: "expired-session", session_expires_at: 1.day.ago)

    get connect_form_settings_providers_url(provider_key: "enable_banking")

    assert_response :success
    assert_includes response.body, select_bank_enable_banking_item_path(@item)
    assert_not_includes response.body, reauthorize_enable_banking_item_path(@item)
  end

  test "reauthorize redirects with an alert on unexpected errors" do
    @item.update!(aspsp_name: "Test Bank")
    EnableBankingItem.any_instance.stubs(:begin_authorization!).raises(StandardError, "boom")

    assert_difference -> { DebugLogEntry.where(provider_key: "enable_banking", level: "error").count }, 1 do
      post reauthorize_enable_banking_item_url(@item)
    end

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("enable_banking_items.reauthorize.unexpected_error"), flash[:alert]
  end

  test "authorize sends a random state instead of the item id" do
    stub_authorization_start

    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }

    assert_redirected_to "https://api.enablebanking.com/auth/redirect/abc"
    assert_not_equal @item.id, @sent_state
    assert @sent_state.length >= 32
  end

  # One N26 login used to leave five connections behind, four of them empty.
  test "starting a new connection twice for the same bank reuses the pending one" do
    stub_authorization_start

    assert_difference -> { @family.enable_banking_items.count }, 1 do
      2.times do
        post authorize_enable_banking_item_url(@item),
             params: { aspsp_name: "Test Bank", psu_type: "personal", new_connection: "true" }
      end
    end

    assert_redirected_to "https://api.enablebanking.com/auth/redirect/abc"
  end

  test "a new connection to another bank still gets its own connection" do
    stub_authorization_start(banks: [ "Test Bank", "Other Bank" ])

    assert_difference -> { @family.enable_banking_items.count }, 2 do
      post authorize_enable_banking_item_url(@item),
           params: { aspsp_name: "Test Bank", psu_type: "personal", new_connection: "true" }
      post authorize_enable_banking_item_url(@item),
           params: { aspsp_name: "Other Bank", psu_type: "personal", new_connection: "true" }
    end
  end

  test "a connection that already has a session is never reused for a new one" do
    stub_authorization_start
    start_new_connection
    @family.enable_banking_items.order(:created_at).last.update!(session_id: "live-session")

    assert_difference -> { @family.enable_banking_items.count }, 1 do
      start_new_connection
    end
  end

  test "a connection that already has accounts is never reused for a new one" do
    stub_authorization_start
    start_new_connection
    @family.enable_banking_items.order(:created_at).last
      .enable_banking_accounts.create!(name: "Checking", uid: "eb_existing", currency: "EUR")

    assert_difference -> { @family.enable_banking_items.count }, 1 do
      start_new_connection
    end
  end

  # Reuse is limited to connections this browser started: two browsers of one
  # family sharing a pending connection could both complete on it.
  test "a pending connection started in another browser is not reused" do
    stub_authorization_start

    assert_difference -> { @family.enable_banking_items.count }, 2 do
      start_new_connection
      reset!
      sign_in users(:family_admin)
      start_new_connection
    end
  end

  test "a start that failed at the provider is reused on the next attempt" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [ { name: "Test Bank", country: "DE", psu_types: [ "personal" ], auth_methods: [ { approach: "REDIRECT" } ] } ]
    )
    Provider::EnableBanking.any_instance.stubs(:start_authorization)
      .raises(Provider::EnableBanking::EnableBankingError.new("REDIRECT_URI_NOT_ALLOWED"))

    assert_difference -> { @family.enable_banking_items.count }, 1 do
      3.times do
        post authorize_enable_banking_item_url(@item),
             params: { aspsp_name: "Test Bank", psu_type: "personal", new_connection: "true" }
      end
    end
  end

  test "a connection scheduled for deletion is not reused" do
    stub_authorization_start
    start_new_connection
    @family.enable_banking_items.order(:created_at).last.update!(scheduled_for_deletion: true)

    assert_difference -> { @family.enable_banking_items.count }, 1 do
      start_new_connection
    end
  end

  # Two new logins to the same bank now share the pending connection, so only
  # the newest may finish: otherwise the first login's accounts would end up on
  # the second login's session.
  test "of two new logins to the same bank, only the newest can complete" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item),
         params: { aspsp_name: "Test Bank", psu_type: "personal", new_connection: "true" }
    first_state = @sent_state
    post authorize_enable_banking_item_url(@item),
         params: { aspsp_name: "Test Bank", psu_type: "personal", new_connection: "true" }
    second_state = @sent_state
    EnableBankingItem.any_instance.stubs(:sync_later)

    EnableBankingItem.any_instance.expects(:complete_authorization).once
    get callback_enable_banking_items_url, params: { code: "first", state: first_state }
    assert_redirected_to settings_providers_path
    get callback_enable_banking_items_url, params: { code: "second", state: second_state }
    assert_redirected_to accounts_path
  end

  test "a retry that fails to start leaves the earlier login able to complete" do
    stub_authorization_start
    start_new_connection
    first_state = @sent_state
    Provider::EnableBanking.any_instance.stubs(:start_authorization)
      .raises(Provider::EnableBanking::EnableBankingError.new("ASPSP unavailable"))
    start_new_connection
    EnableBankingItem.any_instance.stubs(:sync_later)

    EnableBankingItem.any_instance.expects(:complete_authorization).with(code: "first")
    get callback_enable_banking_items_url, params: { code: "first", state: first_state }
    assert_redirected_to accounts_path
  end

  # Each failed retry used to add a dead state, so enough of them pushed the
  # earlier login's state out of the capped map.
  test "repeated retries that fail to start leave the earlier login able to complete" do
    stub_authorization_start
    start_new_connection
    first_state = @sent_state
    Provider::EnableBanking.any_instance.stubs(:start_authorization)
      .raises(Provider::EnableBanking::EnableBankingError.new("ASPSP unavailable"))
    EnableBankingItemsController::MAX_PENDING_OAUTH_STATES.times { start_new_connection }
    EnableBankingItem.any_instance.stubs(:sync_later)

    EnableBankingItem.any_instance.expects(:complete_authorization).with(code: "first")
    get callback_enable_banking_items_url, params: { code: "first", state: first_state }
    assert_redirected_to accounts_path
  end

  test "a retry the provider sends to an untrusted host leaves the earlier login able to complete" do
    stub_authorization_start
    start_new_connection
    first_state = @sent_state
    Provider::EnableBanking.any_instance.stubs(:start_authorization)
      .returns(url: "https://api.enablebanking.com.evil.test/auth", authorization_id: "auth_2")
    start_new_connection
    assert_redirected_to settings_providers_path
    EnableBankingItem.any_instance.stubs(:sync_later)

    EnableBankingItem.any_instance.expects(:complete_authorization).with(code: "first")
    get callback_enable_banking_items_url, params: { code: "first", state: first_state }
    assert_redirected_to accounts_path
  end

  # The retry's older state is dropped before the cap applies, so it never
  # evicts another bank's login that is still open.
  test "retrying one login keeps the other logins open when the limit is reached" do
    banks = [ "Bank B", "Bank A", "Bank C", "Bank D", "Bank E" ]
    assert_equal EnableBankingItemsController::MAX_PENDING_OAUTH_STATES, banks.size
    stub_authorization_start(banks: banks)
    start_new_connection(bank: "Bank B")
    bank_b_state = @sent_state
    banks.drop(1).each { |bank| start_new_connection(bank: bank) }
    start_new_connection(bank: "Bank A")
    assert_redirected_to "https://api.enablebanking.com/auth/redirect/abc"
    EnableBankingItem.any_instance.stubs(:sync_later)

    EnableBankingItem.any_instance.expects(:complete_authorization).with(code: "bank b")
    get callback_enable_banking_items_url, params: { code: "bank b", state: bank_b_state }
    assert_redirected_to accounts_path
  end

  test "reauthorize issues a state the callback accepts" do
    stub_authorization_start
    @item.update!(aspsp_name: "Test Bank")

    post reauthorize_enable_banking_item_url(@item)
    assert_redirected_to "https://api.enablebanking.com/auth/redirect/abc"
    EnableBankingItem.any_instance.stubs(:sync_later)

    EnableBankingItem.any_instance.expects(:complete_authorization).with(code: "reauth")
    get callback_enable_banking_items_url, params: { code: "reauth", state: @sent_state }
    assert_redirected_to accounts_path
  end

  test "callback completes authorization when the state matches this session" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }

    EnableBankingItem.any_instance.expects(:complete_authorization).with(code: "good-code")
    EnableBankingItem.any_instance.stubs(:sync_later)

    get callback_enable_banking_items_url, params: { code: "good-code", state: @sent_state }

    assert_redirected_to accounts_path
  end

  test "callback rejects the item id as state" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }

    EnableBankingItem.any_instance.expects(:complete_authorization).never

    get callback_enable_banking_items_url, params: { code: "attacker-code", state: @item.id }

    assert_redirected_to settings_providers_path
  end

  test "callback rejects a state that was not issued to this session" do
    EnableBankingItem.any_instance.expects(:complete_authorization).never

    get callback_enable_banking_items_url, params: { code: "attacker-code", state: SecureRandom.urlsafe_base64(32) }

    assert_redirected_to settings_providers_path
  end

  test "callback state can only be used once" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }
    EnableBankingItem.any_instance.stubs(:complete_authorization)
    EnableBankingItem.any_instance.stubs(:sync_later)
    get callback_enable_banking_items_url, params: { code: "good-code", state: @sent_state }

    EnableBankingItem.any_instance.expects(:complete_authorization).never
    get callback_enable_banking_items_url, params: { code: "replayed-code", state: @sent_state }

    assert_redirected_to settings_providers_path
  end

  test "parallel authorizations each keep their own state" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }
    first_state = @sent_state
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }
    second_state = @sent_state
    EnableBankingItem.any_instance.stubs(:sync_later)

    # A stray callback with a made-up state must not cancel pending flows.
    get callback_enable_banking_items_url, params: { code: "stray", state: "made-up" }

    EnableBankingItem.any_instance.expects(:complete_authorization).twice
    get callback_enable_banking_items_url, params: { code: "first", state: first_state }
    assert_redirected_to accounts_path
    get callback_enable_banking_items_url, params: { code: "second", state: second_state }
    assert_redirected_to accounts_path
  end

  # The orphan cleanup's enqueue runs once the relink transaction commits. If it
  # ran inside that transaction, its error would escape the action's rescue
  # after the relink had committed, and the request would fail.
  test "link_existing_account still succeeds when the orphan's destroy enqueue fails" do
    orphan = Account.create!(
      family: @family,
      name: "Old Checking",
      balance: 0,
      currency: "EUR",
      accountable: Depository.create!(subtype: "checking")
    )
    target = Account.create!(
      family: @family,
      name: "Manual Checking",
      balance: 0,
      currency: "EUR",
      accountable: Depository.create!(subtype: "checking")
    )
    eb_account = @item.enable_banking_accounts.create!(
      name: "Checking",
      uid: "eb_relink_1",
      currency: "EUR",
      current_balance: 0
    )
    AccountProvider.create!(account: orphan, provider: eb_account)
    DestroyJob.queue_adapter.expects(:enqueue).once.raises(RedisClient::CannotConnectError, "Connection refused")

    post link_existing_account_enable_banking_items_path, params: {
      account_id: target.id,
      enable_banking_account_id: eb_account.id
    }

    assert_response :see_other
    assert_equal target, AccountProvider.find_by!(provider: eb_account).account
    assert_equal "active", orphan.reload.status
  end

  test "setup_accounts does not offer an ignored account" do
    mine = @item.enable_banking_accounts.create!(name: "Mine", uid: "hash_mine", currency: "EUR")
    theirs = @item.enable_banking_accounts.create!(name: "Theirs", uid: "hash_theirs", currency: "EUR")
    theirs.ignore!

    get setup_accounts_enable_banking_item_url(@item)

    assert_response :success
    assert_select "select[name=?]", "account_types[#{mine.id}]"
    assert_select "select[name=?]", "account_types[#{theirs.id}]", count: 0
  end

  test "complete_account_setup remembers a skipped account as ignored" do
    theirs = @item.enable_banking_accounts.create!(name: "Theirs", uid: "hash_theirs", currency: "EUR", current_balance: 50)

    assert_no_difference "Account.count" do
      post complete_account_setup_enable_banking_item_url(@item), params: { account_types: { theirs.id => "skip" } }
    end

    assert_redirected_to accounts_path
    assert theirs.reload.ignored?
    assert_nil theirs.current_balance
    assert_not @item.reload.pending_account_setup?
  end

  # The modal's form is a plain form_with, so the date field's label and help
  # must be rendered as elements rather than passed as builder options (which
  # end up as unknown attributes on the input).
  test "setup modal shows the start date label and help and leaves the date blank by default" do
    @item.enable_banking_accounts.create!(name: "Checking", uid: "eb_setup_1", currency: "EUR", current_balance: 0)

    get setup_accounts_enable_banking_item_url(@item)

    assert_response :success
    assert_select "label[for=sync_start_date]", text: I18n.t("enable_banking_items.setup_accounts.sync_start_date_label")
    assert_select "p#sync_start_date_help", text: I18n.t("enable_banking_items.setup_accounts.sync_start_date_help")
    assert_select "input[type=date][name=sync_start_date][aria-describedby=sync_start_date_help]" do |inputs|
      assert inputs.first["value"].blank?, "A first setup must not prefill a date, or it would cap the first fetch"
      assert_nil inputs.first["label"]
      assert_nil inputs.first["help_text"]
    end
  end

  test "setup modal shows account types and subtypes in the user's language" do
    @item.enable_banking_accounts.create!(name: "Checking", uid: "eb_setup_1", currency: "EUR", current_balance: 0)

    get setup_accounts_enable_banking_item_url(@item, locale: :de)

    assert_response :success
    I18n.with_locale(:de) do
      assert_select "option[value=Depository]", text: I18n.t("enable_banking_items.setup_accounts.account_types.depository")
      assert_select "option[value=checking]", text: Depository.long_subtype_label_for("checking")
      assert_select "option[value=mortgage]", text: Loan.long_subtype_label_for("mortgage")
      assert_select "label", text: I18n.t("enable_banking_items.setup_accounts.subtype_labels.loan")
    end
    assert_no_match(/Checking or Savings Account|Loan or Mortgage|Account Subtype:/, response.body)
  end

  test "setup modal shows a start date that is already set" do
    @item.update!(sync_start_date: Date.new(2024, 1, 15))
    @item.enable_banking_accounts.create!(name: "Checking", uid: "eb_setup_1", currency: "EUR", current_balance: 0)

    get setup_accounts_enable_banking_item_url(@item)

    assert_select "input[type=date][name=sync_start_date][value='2024-01-15']"
  end

  test "complete_account_setup stores a chosen start date" do
    post complete_account_setup_enable_banking_item_url(@item), params: { sync_start_date: "2024-01-15" }

    assert_equal Date.new(2024, 1, 15), @item.reload.sync_start_date
  end

  test "complete_account_setup with a blank start date leaves it unset" do
    post complete_account_setup_enable_banking_item_url(@item), params: { sync_start_date: "" }

    assert_nil @item.reload.sync_start_date
  end

  test "complete_account_setup with a cleared start date removes the stored one" do
    @item.update!(sync_start_date: Date.new(2024, 1, 15))

    post complete_account_setup_enable_banking_item_url(@item), params: { sync_start_date: "" }

    assert_nil @item.reload.sync_start_date
  end

  test "complete_account_setup without the date field keeps the stored start date" do
    @item.update!(sync_start_date: Date.new(2024, 1, 15))

    post complete_account_setup_enable_banking_item_url(@item), params: { account_types: {} }

    assert_equal Date.new(2024, 1, 15), @item.reload.sync_start_date
  end

  private

    def start_new_connection(bank: "Test Bank")
      post authorize_enable_banking_item_url(@item),
           params: { aspsp_name: bank, psu_type: "personal", new_connection: "true" }
    end

    def stub_authorization_start(banks: [ "Test Bank" ])
      Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
        aspsps: banks.map { |name| { name: name, country: "DE", psu_types: [ "personal" ], auth_methods: [ { approach: "REDIRECT" } ] } }
      )
      test_case = self
      Provider::EnableBanking.any_instance.stubs(:start_authorization).with do |**kwargs|
        test_case.instance_variable_set(:@sent_state, kwargs[:state])
        true
      end.returns(url: "https://api.enablebanking.com/auth/redirect/abc", authorization_id: "auth_1")
    end
end
