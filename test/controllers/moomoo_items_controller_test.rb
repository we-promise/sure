require "test_helper"

class MoomooItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @item = moomoo_items(:connected_item)
    @pending = moomoo_items(:pending_item)
    @moomoo_account = moomoo_accounts(:main_account)
  end

  # The rows hold years of encrypted fills, orders and cash logs; the card
  # needs only the connection's links and status. (The shared account list
  # still preloads each linked account's provider row by id.)
  test "the accounts page loads none of the connection's moomoo rows whole" do
    account = Account.create!(family: @family, name: "moomoo SGD", balance: 0, currency: "SGD", accountable: Investment.new)
    @moomoo_account.ensure_account_provider!(account)
    @moomoo_account.update_column(:last_seen_at, Time.current)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }

    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)}"
    assert_select "a[href=?]", edit_sync_schedule_path(syncable_type: "MoomooItem", syncable_id: @item.id), text: I18n.t("sync_schedules.menu_item")
    whole_rows = queries.grep(/SELECT "moomoo_accounts"\.\* FROM "moomoo_accounts"/)
    assert_empty whole_rows.grep(/"moomoo_item_id"|"primary_moomoo_account_id" IS NULL/)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "connect registers a client for a new connection and sends the browser to moomoo's consent page" do
    @pending.destroy!
    Provider::Moomoo.expects(:register_client).with(redirect_uri: callback_moomoo_items_url).once
      .returns(client_id: "cid-new", registration_access_token: "rat", registration_client_uri: "https://webapi.moomoo.com/oauth2/register/cid-new", scope: nil)

    assert_difference -> { @family.moomoo_items.count }, 1 do
      post connect_moomoo_items_url
    end

    assert_response :see_other
    uri = URI.parse(response.location)
    query = Rack::Utils.parse_query(uri.query)
    assert_equal "webapi.moomoo.com", uri.host
    assert_equal "/oauth2/authorize/confirm", uri.path
    assert_equal callback_moomoo_items_url, query["redirect_uri"]
    assert_equal "cid-new", query["client_id"]
    assert_equal "S256", query["code_challenge_method"]

    item = @family.moomoo_items.order(:created_at).last
    assert_equal "cid-new", item.oauth_client_id
    assert_equal callback_moomoo_items_url, item.oauth_redirect_uri
    assert_not item.connected?
  end

  test "connect reuses a connection that never finished authorizing" do
    Provider::Moomoo.expects(:register_client).never

    assert_no_difference -> { @family.moomoo_items.count } do
      post connect_moomoo_items_url
    end

    assert_equal "test-client-id", consent_query["client_id"]
  end

  test "the callback completes the connection with the PKCE verifier issued for it" do
    post connect_moomoo_items_url
    query = consent_query
    verifier = nil
    Provider::Moomoo.any_instance.expects(:exchange_code).with { |*args|
      params = args.last
      verifier = params[:code_verifier]
      params[:code] == "the-code" && params[:redirect_uri] == callback_moomoo_items_url
    }.returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "trade:read accid:1234567890123456")

    get callback_moomoo_items_url, params: { code: "the-code", state: query["state"] }

    assert_redirected_to setup_accounts_moomoo_item_url(@pending)
    assert_equal I18n.t("moomoo_items.callback.success"), flash[:notice]
    @pending.reload
    assert @pending.connected?
    assert_equal "at", @pending.access_token
    assert_equal 1, @pending.syncs.count
    assert_equal Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false), query["code_challenge"]
  end

  test "a state this session didn't issue completes nothing" do
    MoomooItem.any_instance.expects(:complete_authorization!).never

    get callback_moomoo_items_url, params: { code: "the-code", state: "forged" }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]
  end

  test "a state works once" do
    post connect_moomoo_items_url
    state = consent_query["state"]
    MoomooItem.any_instance.stubs(:complete_authorization!)
    MoomooItem.any_instance.stubs(:sync_later)

    get callback_moomoo_items_url, params: { code: "c1", state: state }
    assert_redirected_to setup_accounts_moomoo_item_url(@pending)

    get callback_moomoo_items_url, params: { code: "c1", state: state }
    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]
  end

  test "a state expires after 15 minutes" do
    post connect_moomoo_items_url
    state = consent_query["state"]
    MoomooItem.any_instance.expects(:complete_authorization!).never

    travel 16.minutes do
      get callback_moomoo_items_url, params: { code: "c1", state: state }
    end

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]
  end

  test "errors moomoo returns on the callback are shown" do
    get callback_moomoo_items_url, params: { error: "access_denied", state: "s" }
    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.access_denied"), flash[:alert]

    post connect_moomoo_items_url
    get callback_moomoo_items_url, params: { error: "server_error", error_description: "Try again later", state: consent_query["state"] }
    assert_redirected_to settings_providers_url
    assert_includes flash[:alert], "Try again later"
  end

  test "an error callback this session didn't start shows none of its text" do
    get callback_moomoo_items_url, params: { error: "server_error", error_description: "Sign in again at https://evil.example" }
    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]

    get callback_moomoo_items_url, params: { error: "Sign in again at https://evil.example", state: "forged" }
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]
  end

  test "a long error description is shortened" do
    post connect_moomoo_items_url

    get callback_moomoo_items_url, params: { error: "server_error", error_description: "A" * 5000, state: consent_query["state"] }

    assert_redirected_to settings_providers_url
    assert_operator flash[:alert].length, :<, 300
  end

  test "a consent that grants order placing is refused and keeps nothing" do
    post connect_moomoo_items_url
    state = consent_query["state"]
    Provider::Moomoo.any_instance.stubs(:exchange_code).returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "trade:read trade:write accid:1")

    assert_no_difference -> { @pending.syncs.count } do
      get callback_moomoo_items_url, params: { code: "c1", state: state }
    end

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.write_scope_granted"), flash[:alert]
    assert_not @pending.reload.connected?
  end

  test "a second consent for a new connection doesn't replace one completed meanwhile" do
    MoomooItem.any_instance.stubs(:sync_later)
    post connect_moomoo_items_url
    first_state = consent_query["state"]
    post connect_moomoo_items_url
    second_state = consent_query["state"]
    Provider::Moomoo.any_instance.stubs(:exchange_code)
      .returns(access_token: "at-1", refresh_token: "rt-1", expires_in: 7200, scope: "trade:read accid:1111")
      .then.returns(access_token: "at-2", refresh_token: "rt-2", expires_in: 7200, scope: "trade:read accid:2222")

    get callback_moomoo_items_url, params: { code: "c1", state: first_state }
    assert_redirected_to setup_accounts_moomoo_item_url(@pending)

    get callback_moomoo_items_url, params: { code: "c2", state: second_state }
    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.already_connected"), flash[:alert]

    @pending.reload
    assert_equal [ "rt-1", "trade:read accid:1111" ], [ @pending.refresh_token, @pending.oauth_scope ]
  end

  test "a healthy connection changes its shared accounts in place" do
    ensure_tailwind_build
    get connect_form_settings_providers_url(provider_key: "moomoo")
    assert_select "#moomoo-providers-panel form[action=?] button[data-turbo='false']", reauthorize_moomoo_item_path(@item),
                  text: /#{I18n.t("settings.providers.moomoo_panel.change_accounts")}/
    get accounts_url
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)} form[action=?] button[data-turbo='false']", reauthorize_moomoo_item_path(@item),
                  text: /#{I18n.t("moomoo_items.moomoo_item.change_accounts")}/

    Provider::Moomoo.expects(:register_client).never
    MoomooItem.any_instance.stubs(:sync_later)
    assert_no_difference -> { @family.moomoo_items.count } do
      post reauthorize_moomoo_item_url(@item)
    end
    state = consent_query["state"]
    Provider::Moomoo.any_instance.stubs(:exchange_code)
      .returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "trade:read accid:1234567890123456 accid:7777000011112222")

    get callback_moomoo_items_url, params: { code: "c1", state: state }

    assert_redirected_to setup_accounts_moomoo_item_url(@item)
    assert_equal "trade:read accid:1234567890123456 accid:7777000011112222", @item.reload.oauth_scope
  end

  test "changing accounts from another address keeps the working registration until a consent completes" do
    callback = "http://sure.home.example.com/moomoo_items/callback"
    host! "sure.home.example.com"
    sign_in @user
    client_id = "00000000-0000-4000-8000-000000000001"
    Provider::Moomoo.expects(:register_client).with(redirect_uri: callback).once.returns(
      client_id: client_id, registration_access_token: "registration-token-home",
      registration_client_uri: "https://webapi.moomoo.com/oauth2/register/#{client_id}", scope: "quote:read quote:write trade:read trade:write accid:*"
    )

    # Each consent started again reuses that one registration.
    states = Array.new(MoomooItemsController::MAX_PENDING_OAUTH_STATES) do
      post reauthorize_moomoo_item_url(@item)
      assert_equal [ client_id, callback ], consent_query.values_at("client_id", "redirect_uri")
      consent_query["state"]
    end

    get callback_moomoo_items_url, params: { error: "access_denied", state: states.last }

    @item.reload
    assert_equal [ "test-client-id", "http://www.example.com/moomoo_items/callback" ], [ @item.oauth_client_id, @item.oauth_redirect_uri ]
    assert_equal "test-client-id", @item.moomoo_provider.client_id
    assert_equal client_id, @item.pending_oauth_client["client_id"]
    assert @item.good?
  end

  test "a consent completed from another address moves the connection onto its new registration" do
    callback = "http://sure.lan/moomoo_items/callback"
    host! "sure.lan"
    sign_in @user
    Provider::Moomoo.stubs(:register_client)
      .returns(client_id: "cid-lan", registration_access_token: "rat-lan", registration_client_uri: "https://webapi.moomoo.com/oauth2/register/cid-lan", scope: "trade:read accid:*")
    MoomooItem.any_instance.stubs(:sync_later)
    post reauthorize_moomoo_item_url(@item)
    token_request = nil
    stub_request(:post, "#{Provider::Moomoo::BASE_URL}#{Provider::Moomoo::TOKEN_PATH}").to_return do |request|
      token_request = URI.decode_www_form(request.body).to_h
      { status: 200, body: { access_token: "at-lan", refresh_token: "rt-lan", expires_in: 7200, scope: "trade:read accid:1234567890123456" }.to_json }
    end

    get callback_moomoo_items_url, params: { code: "c1", state: consent_query["state"] }

    assert_redirected_to setup_accounts_moomoo_item_url(@item)
    assert_equal [ "cid-lan", callback ], token_request.values_at("client_id", "redirect_uri")
    @item.reload
    assert_equal [ "cid-lan", callback, "trade:read accid:*", "rat-lan", "https://webapi.moomoo.com/oauth2/register/cid-lan" ],
                 [ @item.oauth_client_id, @item.oauth_redirect_uri, @item.oauth_registered_scope, @item.oauth_registration_access_token, @item.oauth_registration_client_uri ]
    assert_equal [ "at-lan", "rt-lan" ], [ @item.access_token, @item.refresh_token ]
    assert_nil @item.pending_oauth_client
  end

  test "a consent started before a later registration for another address can't finish" do
    host! "sure.lan"
    sign_in @user
    Provider::Moomoo.stubs(:register_client)
      .returns(client_id: "cid-lan", registration_access_token: nil, registration_client_uri: nil, scope: nil)
    post reauthorize_moomoo_item_url(@item)
    state = consent_query["state"]
    @item.update!(pending_oauth_client: { "client_id" => "cid-vpn", "redirect_uri" => "http://sure.vpn/moomoo_items/callback" })
    Provider::Moomoo.any_instance.expects(:exchange_code).never

    get callback_moomoo_items_url, params: { code: "c1", state: state }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]
    assert_equal [ "test-client-id", "test_refresh" ], [ @item.reload.oauth_client_id, @item.refresh_token ]
  end

  test "a consent finishing after another address's consent moved the connection is refused without spending its code" do
    MoomooItem.any_instance.stubs(:sync_later)
    post reauthorize_moomoo_item_url(@item)
    state = consent_query["state"]

    # Change accounts on another address, completed first.
    host! "sure.lan"
    sign_in @user
    Provider::Moomoo.stubs(:register_client).returns(client_id: "cid-lan", registration_access_token: nil, registration_client_uri: nil, scope: nil)
    post reauthorize_moomoo_item_url(@item)
    stub_token_endpoint
    get callback_moomoo_items_url, params: { code: "c2", state: consent_query["state"] }
    assert_redirected_to setup_accounts_moomoo_item_url(@item)

    host! "www.example.com"
    get callback_moomoo_items_path, params: { code: "c1", state: state }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]
    assert_equal [ "c2" ], @token_requests.map { |request| request["code"] }
    assert_equal [ "cid-lan", "rt-c2" ], [ @item.reload.oauth_client_id, @item.refresh_token ]
  end

  test "a consent doesn't keep its tokens when another consent moves the connection to its client during the code exchange" do
    MoomooItem.any_instance.stubs(:sync_later)
    post reauthorize_moomoo_item_url(@item)
    state = consent_query["state"]
    Provider::Moomoo.stubs(:register_client).returns(client_id: "cid-lan", registration_access_token: nil, registration_client_uri: nil, scope: nil)
    lan_client = @item.reload.oauth_client_for_consent!(redirect_uri: "http://sure.lan/moomoo_items/callback")
    stub_token_endpoint(during: { "c1" => -> { MoomooItem.find(@item.id).complete_authorization!(code: "c2", code_verifier: "v2", client_id: lan_client) } })

    get callback_moomoo_items_url, params: { code: "c1", state: state }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]
    assert_equal [ "cid-lan", "rt-c2" ], [ @item.reload.oauth_client_id, @item.refresh_token ]
  end

  test "a Connect consent doesn't keep its tokens when Connect on another address registers its connection again during the code exchange" do
    MoomooItem.any_instance.stubs(:sync_later)
    post connect_moomoo_items_url
    state = consent_query["state"]
    Provider::Moomoo.stubs(:register_client).returns(client_id: "cid-lan", registration_access_token: nil, registration_client_uri: nil, scope: nil)
    stub_token_endpoint(during: { "c1" => -> { assert_equal @pending, @family.moomoo_item_for_new_connection(redirect_uri: "http://sure.lan/moomoo_items/callback") } })

    get callback_moomoo_items_url, params: { code: "c1", state: state }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.invalid_callback"), flash[:alert]
    @pending.reload
    assert_equal "cid-lan", @pending.oauth_client_id
    assert_not @pending.connected?
  end

  test "consents started together on another address all finish once the first moves the connection onto their client" do
    host! "sure.lan"
    sign_in @user
    Provider::Moomoo.stubs(:register_client).returns(client_id: "cid-lan", registration_access_token: nil, registration_client_uri: nil, scope: nil)
    MoomooItem.any_instance.stubs(:sync_later)
    post reauthorize_moomoo_item_url(@item)
    first = consent_query["state"]
    post reauthorize_moomoo_item_url(@item)
    second = consent_query["state"]
    stub_token_endpoint(scopes: { "c2" => "trade:read accid:1234567890123456 accid:7777000011112222" })

    get callback_moomoo_items_url, params: { code: "c1", state: first }
    get callback_moomoo_items_url, params: { code: "c2", state: second }

    assert_redirected_to setup_accounts_moomoo_item_url(@item)
    assert_equal [ "cid-lan" ], @token_requests.map { |request| request["client_id"] }.uniq
    @item.reload
    assert_equal [ "cid-lan", "rt-c2", "trade:read accid:1234567890123456 accid:7777000011112222" ], [ @item.oauth_client_id, @item.refresh_token, @item.oauth_scope ]
  end

  test "a consent started late in a pending client's reuse window still finishes after a newer registration" do
    host! "sure.lan"
    sign_in @user
    registration = ->(client_id) { { client_id: client_id, registration_access_token: "rat-#{client_id}", registration_client_uri: nil, scope: nil } }
    Provider::Moomoo.stubs(:register_client).returns(registration.("cid-1")).then.returns(registration.("cid-2"))
    MoomooItem.any_instance.stubs(:sync_later)

    post reauthorize_moomoo_item_url(@item)
    travel 14.minutes
    post reauthorize_moomoo_item_url(@item)
    late = consent_query
    travel 2.minutes
    post reauthorize_moomoo_item_url(@item)
    assert_equal [ "cid-1", "cid-2" ], [ late["client_id"], consent_query["client_id"] ]
    stub_token_endpoint

    get callback_moomoo_items_url, params: { code: "c1", state: late["state"] }

    assert_redirected_to setup_accounts_moomoo_item_url(@item)
    assert_equal [ [ "cid-1", "http://sure.lan/moomoo_items/callback" ] ], @token_requests.map { |request| request.values_at("client_id", "redirect_uri") }
    assert_equal [ "cid-1", "rat-cid-1", "rt-c1" ], [ @item.reload.oauth_client_id, @item.oauth_registration_access_token, @item.refresh_token ]
  end

  test "a refused grant leaves what moomoo granted in the debug log" do
    post reauthorize_moomoo_item_url(@item)
    state = consent_query["state"]
    stub_token_endpoint(scopes: { "c1" => "quote:read accid:1234567890123456" })

    get callback_moomoo_items_url, params: { code: "c1", state: state }

    assert_equal I18n.t("moomoo_items.callback.scope_missing"), flash[:alert]
    refused = DebugLogEntry.where(source: "moomoo", category: "provider_auth").where("message LIKE ?", "%grant refused%")
    assert_equal [ [ "quote:read" ] ], refused.map { |entry| entry.metadata["granted"] }
  end

  test "consents started again and again on another address fit in the cookie of an SSO session" do
    host! "sure.lan"
    sso_sign_in(id_token_length: 800)
    Provider::Moomoo.stubs(:register_client)
      .returns(client_id: "00000000-0000-4000-8000-000000000001", registration_access_token: "x", registration_client_uri: nil, scope: nil)

    5.times do
      post reauthorize_moomoo_item_url(@item)
      assert_equal "webapi.moomoo.com", URI.parse(response.location).host
    end
  end

  test "consents running in parallel each complete their own connection" do
    @item.update!(status: :requires_update, reauth_reason: "invalid_grant")
    post reauthorize_moomoo_item_url(@item)
    reconnect_state = consent_query["state"]
    post connect_moomoo_items_url
    connect_state = consent_query["state"]
    MoomooItem.any_instance.stubs(:complete_authorization!)
    MoomooItem.any_instance.stubs(:sync_later)

    get callback_moomoo_items_url, params: { code: "c2", state: connect_state }
    assert_redirected_to setup_accounts_moomoo_item_url(@pending)

    get callback_moomoo_items_url, params: { code: "c1", state: reconnect_state }
    assert_redirected_to setup_accounts_moomoo_item_url(@item)
  end

  test "a consent without trade:read asks to connect again" do
    post connect_moomoo_items_url
    state = consent_query["state"]
    Provider::Moomoo.any_instance.stubs(:exchange_code).returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "quote:read accid:1")

    get callback_moomoo_items_url, params: { code: "c1", state: state }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.scope_missing"), flash[:alert]
    @pending.reload
    assert_not @pending.connected?
    assert @pending.good?
  end

  test "changing accounts without trade:read keeps the working connection" do
    post reauthorize_moomoo_item_url(@item)
    state = consent_query["state"]
    Provider::Moomoo.any_instance.stubs(:exchange_code).returns(access_token: "at", refresh_token: "rt", expires_in: 7200, scope: "accid:1234567890123456")

    get callback_moomoo_items_url, params: { code: "c1", state: state }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.scope_missing"), flash[:alert]
    @item.reload
    assert @item.good?
    assert_equal [ "test_access", "test_refresh" ], [ @item.access_token, @item.refresh_token ]

    assert_difference -> { @item.syncs.count }, 1 do
      post sync_moomoo_item_url(@item)
    end
  end

  test "a second consent without trade:read reports the connection already completed and leaves it alone" do
    MoomooItem.any_instance.stubs(:sync_later)
    post connect_moomoo_items_url
    first_state = consent_query["state"]
    post connect_moomoo_items_url
    second_state = consent_query["state"]
    Provider::Moomoo.any_instance.stubs(:exchange_code)
      .returns(access_token: "at-1", refresh_token: "rt-1", expires_in: 7200, scope: "trade:read accid:1111")
      .then.returns(access_token: "at-2", refresh_token: "rt-2", expires_in: 7200, scope: "accid:2222")

    get callback_moomoo_items_url, params: { code: "c1", state: first_state }
    get callback_moomoo_items_url, params: { code: "c2", state: second_state }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.callback.already_connected"), flash[:alert]
    @pending.reload
    assert @pending.good?
    assert_equal [ "rt-1", "trade:read accid:1111" ], [ @pending.refresh_token, @pending.oauth_scope ]
  end

  test "a failed registration stays on Sure and leaves no connection behind" do
    @pending.destroy!
    Provider::Moomoo.stubs(:register_client)
      .raises(Provider::Moomoo::MoomooError.new("moomoo client registration failed (400): redirect_uri not allowed", :registration_failed, status: 400))

    assert_no_difference -> { @family.moomoo_items.count } do
      post connect_moomoo_items_url
    end

    assert_redirected_to settings_providers_url
    assert_includes flash[:alert], "redirect_uri not allowed"
  end

  test "an authorization address off moomoo's hosts is not followed" do
    Provider::Moomoo.any_instance.stubs(:authorization_url)
      .returns("https://evil.test/oauth2/authorize/confirm", "https://moomoo.com.evil.test/confirm", "http://webapi.moomoo.com/oauth2/authorize/confirm")

    3.times do
      post connect_moomoo_items_url
      assert_redirected_to settings_providers_url
      assert_equal I18n.t("moomoo_items.redirect_blocked"), flash[:alert]
    end
  end

  test "reconnect starts a full consent with the stored client" do
    @item.update!(status: :requires_update, reauth_reason: "invalid_grant")
    Provider::Moomoo.expects(:register_client).never

    post reauthorize_moomoo_item_url(@item)

    assert_response :see_other
    assert_equal "webapi.moomoo.com", URI.parse(response.location).host
    assert_equal "test-client-id", consent_query["client_id"]
  end

  test "only admins connect" do
    sign_in users(:family_member)
    Provider::Moomoo.expects(:register_client).never

    post connect_moomoo_items_url

    assert_redirected_to accounts_url
  end

  test "a connection that needs authorizing is not synced" do
    MoomooItem.any_instance.expects(:sync_later).never

    post sync_moomoo_item_url(@pending)

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.sync.reconnect_first"), flash[:alert]
  end

  test "sync queues a sync for a connected item" do
    assert_difference -> { @item.syncs.count }, 1 do
      post sync_moomoo_item_url(@item)
    end
  end

  test "another family's connection is not found" do
    other = families(:empty).moomoo_items.create!(name: "moomoo", oauth_client_id: "c", refresh_token: "r")

    post sync_moomoo_item_url(other)

    assert_response :not_found
  end

  test "setup offers securities accounts and lists the others as unsupported" do
    ensure_tailwind_build
    @item.moomoo_accounts.create!(moomoo_account_id: "2222", name: "moomoo SG ••2222", currency: "SGD", account_kind: "futures", enable_markets: [ 5 ])

    get setup_accounts_moomoo_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]']", count: 1
    assert_select "input[name='account_ids[]'][value=?]", @moomoo_account.id
    assert_select "#moomoo-unsupported-accounts", text: /moomoo SG ••2222/
  end

  test "the setup page fetches itself again while the first sync is still discovering the accounts" do
    ensure_tailwind_build
    item = @family.moomoo_items.create!(name: "moomoo", oauth_client_id: "c", refresh_token: "r")
    item.sync_later

    get setup_accounts_moomoo_item_url(item)

    assert_response :success
    assert_select "turbo-frame#moomoo-setup-accounts [data-controller=polling][data-polling-frame-id-value=moomoo-setup-accounts][data-polling-url-value=?]", setup_accounts_moomoo_item_path(item)
    assert_select "input[name='account_ids[]']", count: 0

    # What the poll fetches: the frame alone, without the page around it.
    get setup_accounts_moomoo_item_url(item), headers: { "Turbo-Frame" => "moomoo-setup-accounts" }

    assert_response :success
    assert_select "turbo-frame#moomoo-setup-accounts [data-controller=polling]"
    assert_select "title", count: 0

    # The sync can still add rows (the split by currency), and setup waits
    # for it, so the list keeps polling with its buttons off until it ends.
    item.moomoo_accounts.create!(moomoo_account_id: "3333", name: "moomoo SG ••3333", currency: "SGD", account_kind: "securities", enable_markets: [ 1 ])

    get setup_accounts_moomoo_item_url(item), headers: { "Turbo-Frame" => "moomoo-setup-accounts" }

    assert_response :success
    assert_select "turbo-frame#moomoo-setup-accounts #moomoo-setup-still-syncing[data-controller=polling][data-polling-frame-id-value=moomoo-setup-accounts]"
    assert_select "turbo-frame#moomoo-setup-accounts input[name='account_ids[]']", count: 1
    assert_select "button[type=submit][disabled]", text: I18n.t("moomoo_items.setup_accounts.buttons.create_selected_accounts")

    item.syncs.ordered.first.update!(status: "completed", completed_at: Time.current)
    get setup_accounts_moomoo_item_url(item)

    assert_response :success
    assert_select "[data-controller=polling]", count: 0
    assert_select "turbo-frame#moomoo-setup-accounts input[name='account_ids[]']", count: 1
    assert_select "button[type=submit]:not([disabled])", text: I18n.t("moomoo_items.setup_accounts.buttons.create_selected_accounts")
  end

  test "setup leaves out the rows of an account the last import didn't fetch" do
    ensure_tailwind_build
    @moomoo_account.update!(role: "stocks", last_seen_at: 1.day.ago)
    linked_cash = @item.moomoo_accounts.create!(
      moomoo_account_id: @moomoo_account.moomoo_account_id, primary_moomoo_account: @moomoo_account, role: "cash",
      name: "moomoo SG ••3456 (SGD cash)", currency: "SGD", account_kind: "securities"
    )
    linked_cash.ensure_account_provider!(Account.create!(family: @family, name: "SGD cash", balance: 0, currency: "SGD", accountable: Depository.new))
    unseen_cash = @item.moomoo_accounts.create!(
      moomoo_account_id: @moomoo_account.moomoo_account_id, primary_moomoo_account: @moomoo_account, role: "cash",
      name: "moomoo SG ••3456 (USD cash)", currency: "USD", account_kind: "securities"
    )
    fetched = @item.moomoo_accounts.create!(moomoo_account_id: "7777", name: "moomoo SG ••7777", currency: "SGD",
                                            account_kind: "securities", last_seen_at: Time.current)

    get setup_accounts_moomoo_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]']", count: 1
    assert_select "input[name='account_ids[]'][value=?]", fetched.id
    assert_equal 1, @item.unlinked_accounts_count

    assert_no_difference -> { Account.count } do
      post complete_account_setup_moomoo_item_url(@item), params: { account_ids: [ @moomoo_account.id, unseen_cash.id ] }
    end
    assert_nil unseen_cash.reload.current_account
  end

  test "a connection being removed offers and takes no accounts" do
    @item.update!(scheduled_for_deletion: true)

    get setup_accounts_moomoo_item_url(@item)
    assert_response :not_found

    assert_no_difference -> { Account.count + AccountProvider.count } do
      post complete_account_setup_moomoo_item_url(@item), params: { account_ids: [ @moomoo_account.id ] }
    end
    assert_response :not_found
  end

  test "a poll after the first sync failed shows the failure without syncing again, and a visit syncs again" do
    ensure_tailwind_build
    @item.moomoo_accounts.destroy_all
    @item.syncs.create!(status: "failed", failed_at: Time.current, error: "timeout")

    MoomooItem.any_instance.expects(:sync_later).never
    get setup_accounts_moomoo_item_url(@item), headers: { "Turbo-Frame" => "moomoo-setup-accounts" }

    assert_response :success
    assert_select "turbo-frame#moomoo-setup-accounts #moomoo-setup-sync-failed", text: /#{Regexp.escape(I18n.t("moomoo_items.setup_accounts.status.sync_failed_title"))}/
    assert_select "[data-controller=polling]", count: 0
    assert_select "a[href=?]", setup_accounts_moomoo_item_path(@item), text: I18n.t("moomoo_items.setup_accounts.buttons.try_again")

    MoomooItem.any_instance.unstub(:sync_later)
    MoomooItem.any_instance.expects(:sync_later).once
    get setup_accounts_moomoo_item_url(@item)
  end

  test "setup lists a moomoo Japan margin account as unsupported" do
    ensure_tailwind_build
    @item.moomoo_accounts.create!(moomoo_account_id: "8888", name: "moomoo JP ••8888", currency: "JPY", account_kind: "jp_margin",
                                  security_firm: "FUTUJP", acc_type: "margin", enable_markets: [ 15, 2 ])

    get setup_accounts_moomoo_item_url(@item)

    assert_response :success
    assert_select "input[name='account_ids[]']", count: 1
    assert_select "#moomoo-unsupported-accounts", text: /moomoo JP ••8888 • #{I18n.t("moomoo_items.setup_accounts.unsupported.kinds.jp_margin")}/
  end

  test "setup offers only the investment accounts in its currency that the admin may write to" do
    ensure_tailwind_build
    unshared = member_investment("Member Private IRA")
    read_write = member_investment("Member Shared RW", permission: "read_write")
    full_control = member_investment("Member Shared FC", permission: "full_control")
    [ unshared, read_write, full_control ].each { |account| account.update!(currency: "SGD") }
    own = Account.create!(family: @family, name: "Admin Own", balance: 1, currency: "SGD", accountable: Investment.new)
    own_usd = Account.create!(family: @family, name: "Admin Own USD", balance: 1, currency: "USD", accountable: Investment.new)

    get setup_accounts_moomoo_item_url(@item)

    assert_response :success
    assert_select "select[name='account_id'] option[value=?]", unshared.id, count: 0
    assert_select "select[name='account_id'] option[value=?]", read_write.id, count: 0
    assert_select "select[name='account_id'] option[value=?]", full_control.id, count: 1
    assert_select "select[name='account_id'] option[value=?]", own.id, count: 1
    assert_select "select[name='account_id'] option[value=?]", own_usd.id, count: 0
    assert_no_match(/Member Private IRA/, response.body)
  end

  test "the setup dialog follows the design-system form conventions" do
    ensure_tailwind_build
    @item.moomoo_accounts.create!(moomoo_account_id: "7777000000000000", name: "moomoo SG ••7777", currency: "SGD", account_kind: "securities",
                                  security_firm: "FUTUSG", acc_type: "cash", account_number_mask: "••7777")
    Account.create!(family: @family, name: "Manual brokerage", balance: 0, currency: "SGD", accountable: Investment.new)

    get setup_accounts_moomoo_item_url(@item)

    assert_response :success
    assert_select "div.bg-container-inset > p.font-medium", text: I18n.t("moomoo_items.setup_accounts.info_box.title")
    assert_select "form[action=?]", complete_account_setup_moomoo_item_path(@item) do
      assert_select "input[type=checkbox][name='account_ids[]'].checkbox.checkbox--light", count: 2
      assert_select "div.justify-end > a:first-child + button[type=submit]:last-child", count: 1
      assert_select "button[type=submit].flex-1", count: 0
    end

    link_forms = css_select("form[action='#{link_existing_account_moomoo_items_path}']")
    assert_equal 2, link_forms.size
    select_ids = link_forms.map { |form| form.at_css("select[name=account_id]")["id"] }
    assert_equal select_ids.uniq, select_ids
    link_forms.each do |form|
      select = form.at_css("select[name=account_id]")
      moomoo_account = MoomooAccount.find(form.at_css("input[name=moomoo_account_id]")["value"])
      assert select.key?("required")
      assert_select "label[for=?]", select["id"], text: /#{Regexp.escape(moomoo_account.name)}/
      assert_not_includes form.at_css("button[type=submit]")["class"], "py-1"
    end
  end

  test "the link dialog lists unlinked securities accounts, with Cancel first" do
    manual = Account.create!(family: @family, name: "Manual brokerage", balance: 0, currency: "SGD", accountable: Investment.new)
    @item.moomoo_accounts.create!(moomoo_account_id: "2222", name: "Futures", currency: "SGD", account_kind: "futures")

    get select_existing_account_moomoo_items_url(account_id: manual.id)

    assert_response :success
    assert_select "input[name='moomoo_account_id']", count: 1
    assert_select "input[name='moomoo_account_id'][value=?]", @moomoo_account.id
    assert_select "div.justify-end > a:first-child + button[type=submit]:last-child", count: 1
    assert_select "label span.text-xs.text-secondary",
                  text: I18n.t("moomoo_items.select_existing_account.account_summary", details: "SG • Margin • ••3456 • SGD", balance: Money.new(10000, "SGD").format)
  end

  test "select existing account refuses an account the admin can't write to" do
    get select_existing_account_moomoo_items_url(account_id: member_investment.id)
    assert_response :not_found

    get select_existing_account_moomoo_items_url(account_id: member_investment("Member Shared RW", permission: "read_write").id)
    assert_redirected_to accounts_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "link existing account refuses an account the admin can't write to" do
    unshared = member_investment
    read_write = member_investment("Member Shared RW", permission: "read_write")

    assert_no_difference -> { AccountProvider.count } do
      post link_existing_account_moomoo_items_url, params: { account_id: unshared.id, moomoo_account_id: @moomoo_account.id }
      assert_redirected_to settings_providers_url
      assert_equal I18n.t("moomoo_items.link_existing_account.not_found"), flash[:alert]

      post link_existing_account_moomoo_items_url, params: { account_id: read_write.id, moomoo_account_id: @moomoo_account.id }
      assert_redirected_to accounts_url
      assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    end

    [ unshared, read_write ].each do |account|
      account.reload
      assert_equal [ "USD", BigDecimal("12345.67") ], [ account.currency, account.balance ]
    end
    assert_nil @moomoo_account.reload.current_account
  end

  test "link existing account accepts an account shared with full control" do
    account = member_investment("Member Shared FC", permission: "full_control")
    @moomoo_account.update!(currency: account.currency)

    assert_difference -> { AccountProvider.count }, 1 do
      post link_existing_account_moomoo_items_url, params: { account_id: account.id, moomoo_account_id: @moomoo_account.id }
    end

    assert_redirected_to account_url(account)
    assert_equal account, @moomoo_account.reload.current_account
  end

  test "link existing account offers and links only a moomoo account in the account's currency" do
    usd = Account.create!(family: @family, name: "Manual USD brokerage", balance: 500, currency: "USD", accountable: Investment.new)

    get select_existing_account_moomoo_items_url(account_id: usd.id)
    assert_select "input[name='moomoo_account_id'][value=?]", @moomoo_account.id, count: 0

    assert_no_difference -> { AccountProvider.count } do
      post link_existing_account_moomoo_items_url, params: { account_id: usd.id, moomoo_account_id: @moomoo_account.id }
    end
    assert_redirected_to account_url(usd)
    assert_equal I18n.t("moomoo_items.link_existing_account.currency_mismatch", currency: @moomoo_account.currency), flash[:alert]
    assert_equal "USD", usd.reload.currency
    assert_nil @moomoo_account.reload.current_account
  end

  test "the link dialog leaves out, and linking refuses, the rows of an account the last import didn't fetch" do
    @moomoo_account.update!(role: "stocks", last_seen_at: 1.day.ago)
    linked_cash = @item.moomoo_accounts.create!(
      moomoo_account_id: @moomoo_account.moomoo_account_id, primary_moomoo_account: @moomoo_account, role: "cash",
      name: "moomoo SG ••3456 (SGD cash)", currency: "SGD", account_kind: "securities"
    )
    linked_cash.ensure_account_provider!(Account.create!(family: @family, name: "SGD cash", balance: 0, currency: "SGD", accountable: Depository.new))
    unseen_cash = @item.moomoo_accounts.create!(
      moomoo_account_id: @moomoo_account.moomoo_account_id, primary_moomoo_account: @moomoo_account, role: "cash",
      name: "moomoo SG ••3456 (USD cash)", currency: "USD", account_kind: "securities"
    )
    fetched = @item.moomoo_accounts.create!(moomoo_account_id: "7777", name: "moomoo SG ••7777", currency: "SGD",
                                            account_kind: "securities", last_seen_at: Time.current)
    usd_cash = Account.create!(family: @family, name: "Manual USD cash", balance: 0, currency: "USD", accountable: Depository.new)
    brokerage = Account.create!(family: @family, name: "Manual brokerage", balance: 0, currency: "SGD", accountable: Investment.new)

    get select_existing_account_moomoo_items_url(account_id: usd_cash.id)
    assert_response :success
    assert_select "input[name='moomoo_account_id'][value=?]", unseen_cash.id, count: 0

    get select_existing_account_moomoo_items_url(account_id: brokerage.id)
    assert_select "input[name='moomoo_account_id']", count: 1
    assert_select "input[name='moomoo_account_id'][value=?]", fetched.id

    assert_no_difference [ -> { AccountProvider.count }, -> { @item.syncs.count } ] do
      post link_existing_account_moomoo_items_url, params: { account_id: usd_cash.id, moomoo_account_id: unseen_cash.id }
      assert_redirected_to account_url(usd_cash)
      assert_equal I18n.t("moomoo_items.link_existing_account.not_shared"), flash[:alert]

      post link_existing_account_moomoo_items_url, params: { account_id: brokerage.id, moomoo_account_id: @moomoo_account.id }
      assert_redirected_to account_url(brokerage)
      assert_equal I18n.t("moomoo_items.link_existing_account.not_shared"), flash[:alert]
    end
    assert_nil unseen_cash.reload.current_account
    assert_nil @moomoo_account.reload.current_account
  end

  test "complete account setup creates an investment account in the account currency" do
    futures = @item.moomoo_accounts.create!(moomoo_account_id: "2222", name: "Futures", currency: "SGD", account_kind: "futures")

    assert_difference -> { Account.count }, 1 do
      post complete_account_setup_moomoo_item_url(@item), params: { account_ids: [ @moomoo_account.id, futures.id ] }
    end

    assert_redirected_to accounts_url
    account = @moomoo_account.reload.current_account
    assert_equal "Investment", account.accountable_type
    assert_equal "brokerage", account.accountable.subtype
    assert_equal "SGD", account.currency
    assert_nil futures.reload.current_account
  end

  test "complete account setup leaves the processing to the sync it queues" do
    MoomooAccount::Processor.expects(:new).never

    assert_difference -> { @item.syncs.count }, 1 do
      post complete_account_setup_moomoo_item_url(@item), params: { account_ids: [ @moomoo_account.id ] }
    end

    assert_redirected_to accounts_url
    assert @moomoo_account.reload.current_account
  end

  test "setting up and linking accounts wait for a sync under way" do
    @item.sync_later
    MoomooAccount::Processor.expects(:new).never
    manual = Account.create!(family: @family, name: "Manual moomoo", balance: 0, currency: "SGD", accountable: Investment.new)

    assert_no_difference -> { Account.count + AccountProvider.count } do
      post complete_account_setup_moomoo_item_url(@item), params: { account_ids: [ @moomoo_account.id ] }
      assert_redirected_to setup_accounts_moomoo_item_url(@item)
      assert_equal I18n.t("moomoo_items.complete_account_setup.syncing"), flash[:alert]

      post link_existing_account_moomoo_items_url, params: { account_id: manual.id, moomoo_account_id: @moomoo_account.id }
      assert_redirected_to account_url(manual)
      assert_equal I18n.t("moomoo_items.link_existing_account.syncing"), flash[:alert]
    end

    assert_nil @moomoo_account.reload.current_account
  end

  test "links a moomoo account to a manual investment account only" do
    # Each step would otherwise wait for the sync the one before asked for.
    MoomooItem.any_instance.stubs(:sync_later)
    manual = Account.create!(family: @family, name: "Manual moomoo", balance: 0, currency: "SGD", accountable: Investment.new)

    post link_existing_account_moomoo_items_url, params: { account_id: manual.id, moomoo_account_id: @moomoo_account.id }

    assert_redirected_to account_url(manual)
    assert_equal manual, @moomoo_account.reload.current_account

    another = @item.moomoo_accounts.create!(moomoo_account_id: "3333", name: "Other", currency: "SGD", account_kind: "securities")
    cash = Account.create!(family: @family, name: "Cash", balance: 0, currency: "SGD", accountable: Depository.new)
    post link_existing_account_moomoo_items_url, params: { account_id: cash.id, moomoo_account_id: another.id }
    assert_equal I18n.t("moomoo_items.link_existing_account.only_matching_manual_account"), flash[:alert]

    second_manual = Account.create!(family: @family, name: "Second", balance: 0, currency: "SGD", accountable: Investment.new)
    post link_existing_account_moomoo_items_url, params: { account_id: second_manual.id, moomoo_account_id: @moomoo_account.id }
    assert_equal I18n.t("moomoo_items.link_existing_account.already_linked"), flash[:alert]
  end

  test "a cash account of a split moomoo account is set up as, or linked to, a cash account" do
    # Each step would otherwise wait for the sync the one before asked for.
    MoomooItem.any_instance.stubs(:sync_later)
    cash_row = @item.moomoo_accounts.create!(
      moomoo_account_id: @moomoo_account.moomoo_account_id, primary_moomoo_account: @moomoo_account, role: "cash",
      name: "moomoo SG ••3456 (USD cash)", currency: "USD", account_kind: "securities", security_firm: "FUTUSG"
    )
    @moomoo_account.update!(role: "stocks")

    post complete_account_setup_moomoo_item_url(@item), params: { account_ids: [ cash_row.id ] }

    account = cash_row.reload.current_account
    assert_equal [ "Depository", "checking", "USD" ], [ account.accountable_type, account.subtype, account.currency ]

    manual_cash = Account.create!(family: @family, name: "Manual cash", balance: 0, currency: "USD", accountable: Depository.new)
    manual_brokerage = Account.create!(family: @family, name: "Manual brokerage", balance: 0, currency: "SGD", accountable: Investment.new)
    get select_existing_account_moomoo_items_url(account_id: manual_cash.id)
    assert_select "input[name='moomoo_account_id']", count: 0
    get select_existing_account_moomoo_items_url(account_id: manual_brokerage.id)
    assert_select "input[name='moomoo_account_id'][value=?]", @moomoo_account.id

    post link_existing_account_moomoo_items_url, params: { account_id: manual_cash.id, moomoo_account_id: @moomoo_account.id }
    assert_equal I18n.t("moomoo_items.link_existing_account.only_matching_manual_account"), flash[:alert]
    assert_nil @moomoo_account.reload.current_account

    cash_row.account_provider.destroy!
    post link_existing_account_moomoo_items_url, params: { account_id: manual_brokerage.id, moomoo_account_id: cash_row.id }
    assert_equal I18n.t("moomoo_items.link_existing_account.only_matching_manual_account"), flash[:alert]
    post link_existing_account_moomoo_items_url, params: { account_id: manual_cash.id, moomoo_account_id: cash_row.id }
    assert_redirected_to account_url(manual_cash)
    assert_equal manual_cash, cash_row.reload.current_account
  end

  test "the setup offers each moomoo account the manual accounts of its type" do
    ensure_tailwind_build
    cash_row = @item.moomoo_accounts.create!(
      moomoo_account_id: @moomoo_account.moomoo_account_id, primary_moomoo_account: @moomoo_account, role: "cash",
      name: "moomoo SG ••3456 (USD cash)", currency: "USD", account_kind: "securities", security_firm: "FUTUSG"
    )
    @moomoo_account.update!(role: "stocks")
    manual_cash = Account.create!(family: @family, name: "Manual cash", balance: 0, currency: "USD", accountable: Depository.new)
    manual_brokerage = Account.create!(family: @family, name: "Manual brokerage", balance: 0, currency: "SGD", accountable: Investment.new)

    get setup_accounts_moomoo_item_url(@item)

    assert_response :success
    options = css_select("form[action='#{link_existing_account_moomoo_items_path}']").to_h do |form|
      [ form.at_css("input[name=moomoo_account_id]")["value"], form.css("select[name=account_id] option").filter_map { |option| option["value"].presence } ]
    end
    assert_equal [ cash_row.id, @moomoo_account.id ].sort, options.keys.sort
    assert_includes options[cash_row.id], manual_cash.id
    assert_includes options[@moomoo_account.id], manual_brokerage.id
    assert_equal [ "Depository" ], Account.where(id: options[cash_row.id]).distinct.pluck(:accountable_type)
    assert_equal [ "Investment" ], Account.where(id: options[@moomoo_account.id]).distinct.pluck(:accountable_type)
  end

  test "remove unlinks the accounts and schedules the connection for deletion" do
    MoomooItem.any_instance.expects(:unlink_all!).with(dry_run: false).once.returns([])
    MoomooItem.any_instance.expects(:destroy_later).once

    delete moomoo_item_url(@item)

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.destroy.success"), flash[:notice]
  end

  test "remove keeps the connection when an account can't be unlinked" do
    MoomooItem.any_instance.stubs(:unlink_all!).returns([ { provider_account_id: @moomoo_account.id, name: "moomoo", provider_link_ids: [], error: "boom" } ])
    MoomooItem.any_instance.expects(:destroy_later).never

    delete moomoo_item_url(@item)

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.destroy.unlink_failed"), flash[:alert]
  end

  test "sync from the panel re-renders the panel in place" do
    ensure_tailwind_build

    post sync_moomoo_item_url(@item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "moomoo-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @item.reload.syncing?
  end

  test "select accounts opens setup for the connected connection" do
    get select_accounts_moomoo_items_url
    assert_redirected_to setup_accounts_moomoo_item_url(@item)

    @item.update!(scheduled_for_deletion: true)
    get select_accounts_moomoo_items_url
    assert_redirected_to settings_providers_url
    assert_equal I18n.t("moomoo_items.select_accounts.not_configured"), flash[:alert]
  end

  test "the accounts page shows connected connections only" do
    ensure_tailwind_build

    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(@pending)}", count: 0
  end

  test "a connection moomoo stopped accepting offers Reconnect on its card" do
    ensure_tailwind_build
    @item.update!(status: :requires_update, reauth_reason: "invalid_grant")

    get accounts_url

    assert_select "##{ActionView::RecordIdentifier.dom_id(@item)} form[action=?] button[data-turbo='false']", reauthorize_moomoo_item_path(@item),
                  text: /#{I18n.t("moomoo_items.moomoo_item.reconnect")}/
  end

  test "the settings panel shows the callback address and leaves Turbo for moomoo's pages" do
    ensure_tailwind_build
    @item.update!(status: :requires_update, reauth_reason: "invalid_grant")

    get connect_form_settings_providers_url(provider_key: "moomoo")

    assert_response :success
    assert_select "#moomoo-providers-panel" do
      assert_select "code", text: callback_moomoo_items_url
      assert_select "form[action=?] button[data-turbo='false']", connect_moomoo_items_path
      assert_select "form[action=?] button[data-turbo='false']", reauthorize_moomoo_item_path(@item)
      assert_select "form[action=?]", reauthorize_moomoo_item_path(@pending), count: 0
      assert_select "p", text: I18n.t("moomoo_items.reauth_reasons.invalid_grant")
    end
  end

  test "a connected moomoo appears under your connections with its status" do
    ensure_tailwind_build
    @pending.destroy!
    row = "details#moomoo-connection > summary"

    get settings_providers_url

    assert_response :success
    assert_select row, text: /#{Regexp.escape(I18n.t("settings.providers.status.ok"))}/
    assert_select row, text: /#{Regexp.escape(I18n.t("settings.providers.meta.reconsent_required"))}/, count: 0

    @item.update!(status: :requires_update, reauth_reason: "scope_missing")
    get settings_providers_url

    assert_select row, text: /#{Regexp.escape(I18n.t("settings.providers.status.warn"))}/
    assert_select row, text: /#{Regexp.escape(I18n.t("settings.providers.meta.reconsent_required"))}/
  end

  test "a connection that never finished authorizing is not listed as connected" do
    ensure_tailwind_build
    @item.destroy!

    get settings_providers_url

    assert_response :success
    assert_select "details#moomoo-connection", count: 0
    assert_select "a[href=?]", connect_form_settings_providers_path(provider_key: "moomoo")
  end

  private

    def consent_query
      Rack::Utils.parse_query(URI.parse(response.location).query)
    end

    # moomoo's token endpoint, issuing tokens named after the code they are
    # for. `during` runs, by code, while that code is being exchanged.
    def stub_token_endpoint(scopes: {}, during: {})
      @token_requests = []
      stub_request(:post, "#{Provider::Moomoo::BASE_URL}#{Provider::Moomoo::TOKEN_PATH}").to_return do |request|
        body = URI.decode_www_form(request.body).to_h
        @token_requests << body
        during[body["code"]]&.call
        {
          status: 200,
          body: { access_token: "at-#{body['code']}", refresh_token: "rt-#{body['code']}", expires_in: 7200,
                  scope: scopes.fetch(body["code"], "trade:read accid:1234567890123456") }.to_json
        }
      end
    end

    # An OIDC session also keeps the id token, for logout, in its cookie.
    def sso_sign_in(id_token_length:)
      identity = oidc_identities(:bob_google)
      OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new(
        provider: identity.provider, uid: identity.uid,
        info: { email: @user.email, name: "Bob Dylan", first_name: "Bob", last_name: "Dylan" },
        credentials: { id_token: "eyJ#{'a' * (id_token_length - 3)}" }
      )
      get "/auth/openid_connect/callback"
      assert_redirected_to root_path
    ensure
      OmniAuth.config.mock_auth[:openid_connect] = nil
    end

    # A manual investment account another member owns, optionally shared with
    # the signed-in admin.
    def member_investment(name = "Member Private IRA", permission: nil)
      account = Account.create!(family: @family, owner: users(:family_member), name: name, balance: 12_345.67, currency: "USD", accountable: Investment.new)
      account.share_with!(@user, permission: permission) if permission
      account
    end
end
