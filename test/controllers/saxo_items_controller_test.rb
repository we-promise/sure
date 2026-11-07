require "test_helper"

class SaxoItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "connection redirects to LIVE Saxo with a temporary state" do
    Setting.saxo_app_key = "test-key"
    Setting.saxo_app_secret = "test-secret"
    post saxo_items_url
    assert_response :redirect
    url = URI.parse(response.location)
    assert_equal "live.logonvalidation.net", url.host
    query = URI.decode_www_form(url.query).to_h
    assert_equal callback_saxo_items_url, query["redirect_uri"]
    assert_equal "test-key", query["client_id"]
    assert SaxoAuthorization.exists?(state_digest: Digest::SHA256.hexdigest(query.fetch("state")))
  end

  test "the new connection dialog offers authorization when configured" do
    Setting.saxo_app_key = "test-key"
    Setting.saxo_app_secret = "test-secret"

    get new_saxo_item_url

    assert_response :success
    assert_select "turbo-frame#modal form[action='#{saxo_items_path}'][method='post']"
    assert_includes response.body, I18n.t("saxo.market_data_setup")
  end

  test "market data failures show actionable guidance on the connection page" do
    item = @user.family.saxo_items.create!
    SaxoItem.any_instance.stubs(:sync_error).returns("Saxo market data may be unavailable")

    get saxo_item_url(item)

    assert_response :success
    assert_includes response.body, I18n.t("saxo.market_data_unavailable")
  end

  test "the new connection dialog directs unconfigured instances to hosting settings" do
    Setting.saxo_app_key = nil
    Setting.saxo_app_secret = nil

    get new_saxo_item_url

    assert_response :success
    assert_select "turbo-frame#modal a[href='#{settings_hosting_path}']"
    assert_select "form[action='#{saxo_items_path}']", count: 0
  end

  test "non-preview users cannot start authorization" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    post saxo_items_url
    assert_redirected_to root_path
  end

  test "an OAuth denial leaves existing connections untouched" do
    state = SaxoAuthorization.begin!(user: @user, item: nil, redirect_uri: callback_saxo_items_url)
    assert_no_difference "SaxoItem.count" do
      get callback_saxo_items_url, params: { state: state, error: "access_denied" }
    end
    assert_redirected_to settings_providers_path
  end

  test "callback records a sanitized token exchange diagnostic" do
    Setting.saxo_app_key = "test-key"
    Setting.saxo_app_secret = "test-secret"
    state = SaxoAuthorization.begin!(user: @user, item: nil, redirect_uri: callback_saxo_items_url)
    stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(status: 400,
      body: { error: "invalid_client", error_description: "sensitive-response" }.to_json)

    assert_no_difference "SaxoItem.count" do
      assert_difference "DebugLogEntry.count", 1 do
        get callback_saxo_items_url, params: { state: state, code: "sensitive-code" }
      end
    end

    assert_redirected_to settings_providers_path
    entry = DebugLogEntry.order(:created_at).last
    assert_equal "saxo", entry.provider_key
    assert_equal @user.family, entry.family
    assert_equal({ "stage" => "token_exchange", "reason" => "http_error", "http_status" => 400,
      "oauth_error" => "invalid_client" }, entry.metadata)
    assert_no_match(/sensitive|test-secret/, entry.attributes.to_json)
  end

  test "a different family cannot access an existing connection" do
    other = Family.where.not(id: @user.family_id).first!
    item = other.saxo_items.create!
    get saxo_item_url(item)
    assert_response :not_found
  end

  test "reconnection replaces credentials on the same connection" do
    Setting.saxo_app_key = "test-key"
    item = @user.family.saxo_items.create!(status: :requires_update, refresh_token: "expired")
    state = SaxoAuthorization.begin!(user: @user, item: item, redirect_uri: callback_saxo_items_url)
    Provider::Saxo.expects(:exchange).returns(access_token: "access", refresh_token: "rotated",
      access_expires_at: 20.minutes.from_now, refresh_expires_at: 40.minutes.from_now)
    SaxoItem.any_instance.expects(:sync_later)
    assert_no_difference "SaxoItem.count" do
      get callback_saxo_items_url, params: { state: state, code: "authorization-code" }
    end
    assert_equal "rotated", item.reload.refresh_token
    assert item.good?
  end

  test "disconnect keeps financial accounts and removes credentials" do
    item = @user.family.saxo_items.create!(refresh_token: "old")
    provider_account = item.saxo_accounts.create!(account_id: "123", name: "PEA", currency: "EUR")
    account = provider_account.link!
    delete saxo_item_url(item)
    assert_redirected_to settings_providers_path
    assert_nil item.reload.refresh_token
    assert_empty account.reload.account_providers
    assert @user.family.accounts.exists?(account.id)
  end

  %w[read_only read_write].each do |permission|
    test "an admin cannot link an investment account shared with #{permission} access" do
      item = @user.family.saxo_items.create!
      provider_account = item.saxo_accounts.create!(account_id: "123", name: "PEA", currency: "EUR")
      target = @user.family.accounts.create!(name: "Shared investment", currency: "EUR", balance: 100,
        owner: users(:family_member), accountable: Investment.new(subtype: "brokerage"))
      target.share_with!(@user, permission: permission)
      SaxoItem.any_instance.expects(:sync_later).never

      get saxo_item_url(item)
      assert_response :success
      assert_select "option[value='#{target.id}']", count: 0

      assert_no_difference "AccountProvider.count" do
        post link_account_saxo_item_url(item), params: { saxo_account_id: provider_account.id, account_id: target.id }
      end
      assert_response :not_found
      assert_nil provider_account.reload.account_provider
      assert_equal BigDecimal("100"), target.reload.balance
    end
  end

  %w[owner full_control].each do |permission|
    test "an admin can link an investment account with #{permission} access" do
      item = @user.family.saxo_items.create!
      provider_account = item.saxo_accounts.create!(account_id: "123", name: "PEA", currency: "EUR")
      owner = permission == "owner" ? @user : users(:family_member)
      target = @user.family.accounts.create!(name: "Writable investment", currency: "EUR", balance: 100,
        owner: owner, accountable: Investment.new(subtype: "brokerage"))
      target.share_with!(@user, permission: permission) unless permission == "owner"
      SaxoItem.any_instance.expects(:sync_later).once

      get saxo_item_url(item)
      assert_response :success
      assert_select "option[value='#{target.id}']", count: 1

      assert_difference "AccountProvider.count", 1 do
        post link_account_saxo_item_url(item), params: { saxo_account_id: provider_account.id, account_id: target.id }
      end
      assert_redirected_to saxo_item_path(item)
      assert_equal target, provider_account.reload.account
    end
  end

  test "callback persists tokens and schedules discovery" do
    Setting.saxo_app_key = "test-key"
    state = SaxoAuthorization.begin!(user: @user, item: nil, redirect_uri: callback_saxo_items_url)
    Provider::Saxo.expects(:exchange).returns(access_token: "access", refresh_token: "refresh",
      access_expires_at: 20.minutes.from_now, refresh_expires_at: 40.minutes.from_now)
    SaxoItem.any_instance.expects(:sync_later)
    assert_difference "@user.family.saxo_items.count" do
      get callback_saxo_items_url, params: { state: state, code: "authorization-code" }
    end
    assert_redirected_to saxo_item_path(@user.family.saxo_items.last)
  end

  test "callback creates the connection when Saxo returns 201" do
    Setting.saxo_app_key = "test-key"
    Setting.saxo_app_secret = "test-secret"
    state = SaxoAuthorization.begin!(user: @user, item: nil, redirect_uri: callback_saxo_items_url)
    stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(status: 201, body: {
      access_token: "access", refresh_token: "refresh", expires_in: 1200, refresh_token_expires_in: 2400
    }.to_json)
    SaxoItem.any_instance.expects(:sync_later)

    assert_difference "@user.family.saxo_items.count", 1 do
      get callback_saxo_items_url, params: { state: state, code: "authorization-code" }
    end
    item = @user.family.saxo_items.last
    assert_redirected_to saxo_item_path(item)
    assert_equal "access", item.access_token
    assert_equal "refresh", item.refresh_token
  end
end
