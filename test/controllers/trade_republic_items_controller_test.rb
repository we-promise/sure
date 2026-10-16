require "test_helper"

class TradeRepublicItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  # Redirecting back to Bank sync would collapse the open connection row. Only
  # this card is replaced, so the other cards keep their state.
  test "sync from the panel re-renders its card in place" do
    item = trade_republic_items(:configured_item)

    post sync_trade_republic_item_url(item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: TradeRepublic::ConnectionCardComponent.dom_id_for(item)
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert item.reload.syncing?
  end

  # The Accounts page's Sync button posts here too, without the panel's source.
  test "sync from the Accounts page goes back to it" do
    post sync_trade_republic_item_url(trade_republic_items(:configured_item)),
         headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml", "Referer" => accounts_url }

    assert_redirected_to accounts_url
  end

  test "a connection whose session ended is not synced" do
    item = trade_republic_items(:configured_item)
    item.update_columns(session_expires_at: 1.minute.ago)

    assert_no_difference "Sync.count" do
      post sync_trade_republic_item_url(item), headers: { "Referer" => accounts_url }
    end

    assert_redirected_to accounts_url
  end

  test "sync from the panel says nothing started for a connection whose session ended" do
    item = trade_republic_items(:configured_item)
    item.update_columns(session_expires_at: 1.minute.ago)

    post sync_trade_republic_item_url(item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: TradeRepublic::ConnectionCardComponent.dom_id_for(item)
    assert_not_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert_select "form[action='#{sync_trade_republic_item_path(item, source: "panel")}']", count: 0
  end

  test "Trade Republic PIN is filtered from logs" do
    parameter_filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered_params = parameter_filter.filter(
      trade_republic_item: {
        pin: "1234",
        shipping: "express"
      }
    )

    assert_equal "[FILTERED]", filtered_params.dig(:trade_republic_item, :pin)
    assert_equal "express", filtered_params.dig(:trade_republic_item, :shipping)
  end

  test "update rejects a changed phone number without a PIN" do
    item = trade_republic_items(:configured_item)
    original_phone_number = item.phone_number
    original_session_blob = item.session_blob

    patch trade_republic_item_url(item), params: {
      trade_republic_item: {
        phone_number: "+491709999999",
        pin: ""
      }
    }

    assert_redirected_to settings_providers_path(anchor: "trade-republic")
    assert_equal I18n.t("trade_republic_items.update.pin_required"), flash[:alert]
    item.reload
    assert_equal original_phone_number, item.phone_number
    assert_equal original_session_blob, item.session_blob
  end

  test "a failed PIN login keeps the connection's PIN form open" do
    item = trade_republic_items(:requires_update_item)
    provider = mock
    provider.expects(:initiate_login).raises(Provider::TradeRepublicClient::Error, "Wrong PIN")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    patch trade_republic_item_url(item), params: { trade_republic_item: { pin: "0000" } },
      headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_turbo_stream action: "replace", target: TradeRepublic::ConnectionCardComponent.dom_id_for(item) do
      assert_select "[data-trade-republic-pin-login-target='form']:not([hidden])"
    end
  end

  test "update keeps the phone number when it is left blank" do
    item = trade_republic_items(:requires_update_item)
    provider = mock
    provider.expects(:initiate_login).returns(
      Provider::TradeRepublicClient::Result.new(data: { "status" => "verification_required", "pending_login_b64" => "pending" })
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    patch trade_republic_item_url(item), params: { trade_republic_item: { phone_number: "", pin: "1234" } }

    assert_equal "+491709876543", item.reload.phone_number
  end

  test "complete account setup creates and links the selected account" do
    item = trade_republic_items(:configured_item)
    provider_account = trade_republic_accounts(:main_account)

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post complete_account_setup_trade_republic_item_url(item), params: {
          account_ids: [ provider_account.id ]
        }
      end
    end

    assert_redirected_to accounts_path
    provider_account.reload
    assert_not_nil provider_account.current_account
  end

  test "complete account setup after the session ended leaves the sync for the next login" do
    item = trade_republic_items(:configured_item)
    item.update_columns(session_expires_at: 1.minute.ago)

    assert_no_difference "Sync.count" do
      post complete_account_setup_trade_republic_item_url(item), params: { account_ids: [ trade_republic_accounts(:main_account).id ] }
    end

    assert_not_nil trade_republic_accounts(:main_account).reload.current_account
  end

  test "linking an existing account after the session ended leaves the sync for the next login" do
    item = trade_republic_items(:configured_item)
    item.update_columns(session_expires_at: 1.minute.ago)
    account = families(:dylan_family).accounts.create!(name: "Manual brokerage", balance: 0, currency: "EUR", accountable: Investment.new)

    assert_no_difference "Sync.count" do
      post link_existing_account_trade_republic_items_url, params: { account_id: account.id, trade_republic_account_id: trade_republic_accounts(:main_account).id }
    end

    assert_equal account, trade_republic_accounts(:main_account).reload.current_account
  end

  test "opening account setup after the session ended starts no sync" do
    item = trade_republic_items(:configured_item)
    item.update_columns(session_expires_at: 1.minute.ago)
    item.trade_republic_accounts.destroy_all

    assert_no_difference "Sync.count" do
      get setup_accounts_trade_republic_item_url(item)
    end
  end

  test "complete account setup creates a Crypto exchange account for the Crypto account" do
    item = trade_republic_items(:configured_item)
    provider_account = item.trade_republic_accounts.create!(
      name: "Trade Republic Crypto", kind: "crypto", trade_republic_account_id: "crypto:DE1", currency: "EUR"
    )

    post complete_account_setup_trade_republic_item_url(item), params: { account_ids: [ provider_account.id ] }

    account = provider_account.reload.current_account
    assert_equal "Crypto", account.accountable_type
    assert_equal "exchange", account.accountable.subtype
  end

  test "complete account setup rolls back an account when linking fails" do
    item = trade_republic_items(:configured_item)
    provider_account = trade_republic_accounts(:main_account)
    TradeRepublicAccount.any_instance.stubs(:ensure_account_provider!).returns(nil)

    assert_no_difference "Account.count" do
      assert_no_difference "AccountProvider.count" do
        post complete_account_setup_trade_republic_item_url(item), params: {
          account_ids: [ provider_account.id ]
        }
      end
    end

    assert_redirected_to setup_accounts_trade_republic_item_path(item)
    assert_equal I18n.t("trade_republic_items.complete_account_setup.partial_failure", count: 1), flash[:alert]
  end

  test "link_existing_account rejects an account already connected to another provider" do
    item = trade_republic_items(:no_session_item)
    trade_republic_account = trade_republic_accounts(:pending_setup_account)
    account = accounts(:connected)
    account.reload
    assert_not_nil account.plaid_account_id

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_trade_republic_items_url, params: {
        account_id: account.id,
        trade_republic_account_id: trade_republic_account.id
      }
    end

    assert_redirected_to account_path(account)
    assert_equal I18n.t("trade_republic_items.link_existing_account.only_manual_investment"), flash[:alert]
    trade_republic_account.reload
    assert_nil trade_republic_account.current_account
    assert_equal item, trade_republic_account.trade_republic_item
  end

  test "link_existing_account links the Crypto account only to a Crypto exchange account" do
    item = trade_republic_items(:configured_item)
    crypto_provider = item.trade_republic_accounts.create!(
      name: "Trade Republic Crypto", kind: "crypto", trade_republic_account_id: "crypto:DE1", currency: "EUR"
    )
    family = item.family
    wallet = family.accounts.create!(name: "Wallet", balance: 0, currency: "EUR", accountable: Crypto.new(subtype: "wallet"))
    exchange = family.accounts.create!(name: "Exchange", balance: 0, currency: "EUR", accountable: Crypto.new(subtype: "exchange"))
    TradeRepublicAccount::Processor.any_instance.stubs(:process)

    post link_existing_account_trade_republic_items_url, params: { account_id: wallet.id, trade_republic_account_id: crypto_provider.id }
    assert_nil crypto_provider.reload.current_account

    post link_existing_account_trade_republic_items_url, params: { account_id: exchange.id, trade_republic_account_id: crypto_provider.id }
    assert_equal exchange, crypto_provider.reload.current_account
  end

  test "account setup offers only matching manual accounts for linking" do
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.create!(
      name: "Trade Republic Crypto", kind: "crypto", trade_republic_account_id: "crypto:DE1", currency: "EUR"
    )
    item.family.accounts.create!(name: "Cold Wallet", balance: 0, currency: "EUR", accountable: Crypto.new(subtype: "wallet"))
    item.family.accounts.create!(name: "Crypto Exchange", balance: 0, currency: "EUR", accountable: Crypto.new(subtype: "exchange"))

    get setup_accounts_trade_republic_item_url(item)

    assert_response :success
    options = css_select("select[name='account_id'] option").map(&:text)
    assert options.any? { |option| option.start_with?("Crypto Exchange") }
    assert_not options.any? { |option| option.start_with?("Cold Wallet") }
  end

  test "link_existing_account does not link the portfolio to a Crypto account" do
    item = trade_republic_items(:configured_item)
    portfolio = trade_republic_accounts(:main_account)
    exchange = item.family.accounts.create!(name: "Exchange", balance: 0, currency: "EUR", accountable: Crypto.new(subtype: "exchange"))

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_trade_republic_items_url, params: { account_id: exchange.id, trade_republic_account_id: portfolio.id }
    end
    assert_equal I18n.t("trade_republic_items.link_existing_account.only_manual_investment"), flash[:alert]
  end

  test "successful QR polling can complete without a phone number" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = mock
    provider.stubs(:login_stage).returns("qr_pending")
    provider.expects(:poll_qr_login).with(pending_login_b64: "qr-pending").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "confirmed", "session_txt" => "qr-session" }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)
    TradeRepublicItem.any_instance.stubs(:syncing?).returns(true)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :success
    item.reload
    assert_predicate item, :good?
    assert_predicate item, :session_configured?
    assert_nil item.pending_login_state
    assert_nil item.phone_number
  end

  test "QR polling exposes transient provider failures as retryable" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = mock
    provider.stubs(:login_stage).returns("qr_pending")
    provider.expects(:poll_qr_login).with(pending_login_b64: "qr-pending").raises(
      Provider::TradeRepublicClient::Timeout,
      "Trade Republic WebSocket timed out"
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :service_unavailable
    assert_equal true, JSON.parse(response.body).fetch("retryable")
    assert_equal "qr-pending", item.reload.pending_login_state
  end

  test "QR polling persists pending state from retryable provider failure" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = mock
    provider.stubs(:login_stage).returns("qr_pending")
    error = Provider::TradeRepublicClient::TransientProviderError.new("Trade Republic login failed")
    error.define_singleton_method(:pending_login_b64) { "qr-pending-with-process" }
    provider.expects(:poll_qr_login).with(pending_login_b64: "qr-pending").raises(error)
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :service_unavailable
    assert_equal true, JSON.parse(response.body).fetch("retryable")
    assert_equal "qr-pending-with-process", item.reload.pending_login_state
  end

  test "a QR poll error for a login replaced meanwhile is superseded" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = mock
    provider.stubs(:login_stage).returns("qr_pending")
    # Another tab starts a newer login while Trade Republic answers.
    provider.expects(:poll_qr_login).with { |**| item.update_columns(pending_login_state: "newer") }
      .raises(Provider::TradeRepublicClient::Error, "boom")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :conflict
    assert_equal "newer", item.reload.pending_login_state
  end

  test "a QR login started while another tab started a newer one leaves that login" do
    item = trade_republic_items(:requires_update_item)
    provider = mock
    provider.expects(:initiate_qr_login).with { item.update_columns(pending_login_state: "newer"); true }
      .returns(Provider::TradeRepublicClient::Result.new(data: { "status" => "qr_pending", "pending_login_b64" => "qr-pending" }))
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post initiate_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :conflict
    assert_equal "newer", item.reload.pending_login_state
  end

  test "a QR poll after a PIN login replaced it is superseded" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "push-pending")
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("waiting_for_approval")
    provider = mock
    provider.expects(:poll_qr_login).never
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :conflict
  end

  test "a QR cancel after a start that never got going leaves a working session" do
    item = trade_republic_items(:configured_item)

    post cancel_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_turbo_stream action: "replace", target: TradeRepublic::ConnectionCardComponent.dom_id_for(item)
    assert_predicate item.reload, :good?
    assert item.session_blob.present?
  end

  test "a QR cancel leaves a PIN login that replaced the QR login" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "push-pending")
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("waiting_for_approval")

    post cancel_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_turbo_stream action: "replace", target: TradeRepublic::ConnectionCardComponent.dom_id_for(item)
    assert_equal "push-pending", item.reload.pending_login_state
  end

  test "the settings page sends back the token of the login it shows" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: login_state("process_id" => "shown-process"))
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("waiting_for_approval")

    get settings_providers_url

    assert_select "[data-trade-republic-login-url-value='#{poll_login_trade_republic_item_path(item, login_token: item.login_token)}']"

    item.update!(pending_login_state: login_state("challenge_id" => "shown-challenge"))
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("qr_pending")

    get settings_providers_url

    assert_select "[data-trade-republic-qr-login-token-value='#{item.login_token}']"
  end

  test "a QR cancel from a page showing an earlier QR login leaves the newer one" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: login_state("challenge_id" => "newer-challenge"))
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("qr_pending")
    earlier_token = Provider::TradeRepublicClient.login_token(login_state("challenge_id" => "earlier-challenge"))

    post cancel_qr_login_trade_republic_item_url(item), params: { login_token: earlier_token },
      headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_turbo_stream action: "replace", target: TradeRepublic::ConnectionCardComponent.dom_id_for(item)
    assert_equal login_state("challenge_id" => "newer-challenge"), item.reload.pending_login_state
  end

  test "a QR cancel ends the QR login its page shows" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: login_state("challenge_id" => "shown-challenge"))
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("qr_pending")

    post cancel_qr_login_trade_republic_item_url(item), params: { login_token: item.login_token },
      headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_nil item.reload.pending_login_state
  end

  test "a QR poll from a page showing an earlier QR login is superseded" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: login_state("challenge_id" => "newer-challenge"))
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("qr_pending")
    provider = mock
    provider.expects(:poll_qr_login).never
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item),
      params: { login_token: Provider::TradeRepublicClient.login_token(login_state("challenge_id" => "earlier-challenge")) },
      headers: { "ACCEPT" => "application/json" }

    assert_response :conflict
  end

  test "a QR start returns the token of the login it started" do
    item = trade_republic_items(:requires_update_item)
    started = login_state("challenge_id" => "started-challenge")
    provider = mock
    provider.expects(:initiate_qr_login)
      .returns(Provider::TradeRepublicClient::Result.new(data: { "status" => "qr_pending", "pending_login_b64" => started }))
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post initiate_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :accepted
    assert_equal Provider::TradeRepublicClient.login_token(started), response.parsed_body["login_token"]
    assert_not_includes response.body, "started-challenge"
  end

  test "a push poll from a page showing an earlier login leaves the login that replaced it" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: login_state("challenge_id" => "newer-challenge"))
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("qr_pending")
    provider = mock
    provider.expects(:complete_login).never
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item, login_token: Provider::TradeRepublicClient.login_token(login_state("process_id" => "earlier-process"))),
      headers: login_poller_headers

    assert_response :no_content
    assert_equal login_state("challenge_id" => "newer-challenge"), item.reload.pending_login_state
  end

  test "an authenticator code for an earlier login leaves the login that replaced it" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: login_state("process_id" => "newer-process"))
    TradeRepublicItem.any_instance.stubs(:login_stage).returns("authenticator_code")
    provider = mock
    provider.expects(:complete_login).never
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post complete_login_trade_republic_item_url(item, login_token: Provider::TradeRepublicClient.login_token(login_state("process_id" => "earlier-process"))),
      params: { trade_republic_login: { code: "123456" } }

    assert_redirected_to settings_providers_path(anchor: "trade-republic")
    assert_equal login_state("process_id" => "newer-process"), item.reload.pending_login_state
  end

  test "QR polling records retryable provider failures for support" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = mock
    provider.stubs(:login_stage).returns("qr_pending")
    provider.expects(:poll_qr_login).raises(Provider::TradeRepublicClient::RateLimited, "Slow down")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    assert_difference -> { DebugLogEntry.where(source: "trade_republic", level: "info").count }, 1 do
      post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }
    end

    assert_response :too_many_requests
    entry = DebugLogEntry.where(source: "trade_republic").order(:created_at).last
    assert_equal families(:dylan_family), entry.family
    assert_includes entry.message, "RateLimited"
  end

  test "QR polling does not log provider response content from malformed responses" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = mock
    provider.stubs(:login_stage).returns("qr_pending")
    provider.expects(:poll_qr_login).raises(
      Provider::TradeRepublicClient::MalformedResponse,
      "Trade Republic returned invalid JSON: unexpected token at '<html>secret-body</html>'"
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    assert_difference -> { DebugLogEntry.where(source: "trade_republic", level: "warn").count }, 1 do
      post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }
    end

    entry = DebugLogEntry.where(source: "trade_republic").order(:created_at).last
    assert_includes entry.message, "MalformedResponse"
    assert_not_includes entry.message, "secret-body"
  end

  test "QR polling does not restore a login cancelled while a retryable poll was in flight" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    error = Provider::TradeRepublicClient::TransientProviderError.new("Trade Republic login failed")
    error.define_singleton_method(:pending_login_b64) { "qr-pending-with-process" }
    provider = Object.new
    provider.define_singleton_method(:login_stage) { |**| "qr_pending" }
    provider.define_singleton_method(:poll_qr_login) do |pending_login_b64:|
      TradeRepublicItem.find(item.id).update!(pending_login_state: nil)
      raise error
    end
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    # The cancel ended this login, so the poller is told it is superseded.
    assert_response :conflict
    assert_nil item.reload.pending_login_state
  end

  test "expired QR poll does not clear a newer QR login" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = Object.new
    provider.define_singleton_method(:login_stage) { |**| "qr_pending" }
    provider.define_singleton_method(:poll_qr_login) do |pending_login_b64:|
      TradeRepublicItem.find(item.id).update!(pending_login_state: "qr-pending-new")
      raise Provider::TradeRepublicClient::LoginExpired, "Trade Republic login expired"
    end
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :conflict
    assert_equal "qr-pending-new", item.reload.pending_login_state
  end

  test "QR polling does not connect a login cancelled while the poll was in flight" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :requires_update
    )
    item.update!(pending_login_state: "qr-pending")
    provider = Object.new
    provider.define_singleton_method(:login_stage) { |**| "qr_pending" }
    provider.define_singleton_method(:poll_qr_login) do |pending_login_b64:|
      TradeRepublicItem.find(item.id).update!(pending_login_state: nil)
      Provider::TradeRepublicClient::Result.new(data: { "status" => "confirmed", "session_txt" => "qr-session" })
    end
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :conflict
    assert_equal false, JSON.parse(response.body).fetch("retryable")
    item.reload
    assert_predicate item, :requires_update?
    assert_not item.session_configured?
    assert_nil item.pending_login_state
  end

  test "successful web login renders a dialog button that closes the modal" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "pending-login")
    provider = mock
    provider.expects(:complete_login).with(pending_login_b64: "pending-login").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "confirmed", "session_txt" => "session" }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)
    TradeRepublicItem.any_instance.stubs(:syncing?).returns(true)

    post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, 'data-action="DS--dialog#close"'
    assert_includes response.body, I18n.t("settings.providers.trade_republic_panel.connection_success.close")
  end

  test "pending push login poll stores the new state without re-rendering the card" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "pending-login")
    provider = mock
    provider.expects(:complete_login).with(pending_login_b64: "pending-login").returns(
      Provider::TradeRepublicClient::Result.new(data: { "status" => "pending", "pending_login_b64" => "pending-login-2" })
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: login_poller_headers

    assert_response :no_content
    assert_empty response.body
    assert_equal "pending-login-2", item.reload.pending_login_state
  end

  test "manual push login status check re-renders only that connection's card while pending" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "pending-login")
    provider = mock
    provider.expects(:complete_login).returns(
      Provider::TradeRepublicClient::Result.new(data: { "status" => "pending" })
    )
    provider.stubs(:login_stage).returns("waiting_for_approval")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    card_id = TradeRepublic::ConnectionCardComponent.dom_id_for(item)
    assert_includes response.body, %(target="#{card_id}")
    assert_not_includes response.body, %(target="trade-republic-providers-panel")
    assert_equal "pending-login", item.reload.pending_login_state
  end

  test "manual push login status check shows a rate limit on the card" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "pending-login")
    provider = mock
    provider.expects(:complete_login).raises(Provider::TradeRepublicClient::RateLimited, "slow down")
    provider.stubs(:login_stage).returns("waiting_for_approval")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, "slow down"
    assert_equal "pending-login", item.reload.pending_login_state
  end

  test "expired push login replaces only that connection's card" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "pending-login")
    provider = mock
    provider.expects(:complete_login).raises(Provider::TradeRepublicClient::LoginExpired, "expired")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    card_id = TradeRepublic::ConnectionCardComponent.dom_id_for(item)
    assert_includes response.body, %(target="#{card_id}")
    assert_not_includes response.body, %(target="trade-republic-providers-panel")
    assert_not_includes response.body, trade_republic_items(:configured_item).name
    assert_nil item.reload.pending_login_state
  end

  test "retryable push login poll failures keep the login pending for the poller's backoff" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "pending-login")
    provider = mock
    provider.expects(:complete_login).twice
      .raises(Provider::TradeRepublicClient::RateLimited, "slow down")
      .then.raises(Provider::TradeRepublicClient::TransientProviderError, "unavailable")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    assert_difference -> { DebugLogEntry.where(source: "trade_republic", level: "info").count }, 2 do
      post poll_login_trade_republic_item_url(item), headers: login_poller_headers
      assert_response :too_many_requests

      post poll_login_trade_republic_item_url(item), headers: login_poller_headers
      assert_response :service_unavailable
    end

    assert_empty response.body
    assert_equal "pending-login", item.reload.pending_login_state
  end

  test "fatal push login poll failure stops polling and shows the error" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "pending-login")
    provider = mock
    provider.expects(:complete_login).raises(Provider::TradeRepublicClient::InvalidChallenge, "Login state is invalid")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    assert_difference -> { DebugLogEntry.where(source: "trade_republic", level: "warn").count }, 1 do
      post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_includes response.body, "Login state is invalid"
    assert_not_includes response.body, 'data-controller="trade-republic-login"'
    assert_nil item.reload.pending_login_state
  end

  test "fatal push login poll failure keeps a newer login started meanwhile" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "old-login")
    provider = mock
    # A new login replaces the state while the old poll waits on the provider.
    provider.expects(:complete_login).with do |pending_login_b64:|
      TradeRepublicItem.where(id: item.id).update_all(pending_login_state: "new-login")
      pending_login_b64 == "old-login"
    end.raises(Provider::TradeRepublicClient::InvalidChallenge, "Login state is invalid")
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: login_poller_headers

    assert_response :no_content
    assert_equal "new-login", item.reload.pending_login_state
  end

  test "completed push login from an old poll keeps a newer login started meanwhile" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "old-login")
    provider = mock
    provider.expects(:complete_login).with do |pending_login_b64:|
      TradeRepublicItem.where(id: item.id).update_all(pending_login_state: "new-login")
      pending_login_b64 == "old-login"
    end.returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "ok", "session_txt" => "old-session", "account" => { "brokerage_account_id" => "DE9999" } }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: login_poller_headers

    assert_response :no_content
    item.reload
    assert_equal "new-login", item.pending_login_state
    assert_not_equal "old-session", item.session_blob
  end

  test "duplicate push login from an old poll keeps a newer login started meanwhile" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :requires_update, pending_login_state: "old-login"
    )
    provider = mock
    provider.expects(:complete_login).with do |pending_login_b64:|
      TradeRepublicItem.where(id: item.id).update_all(pending_login_state: "new-login")
      pending_login_b64 == "old-login"
    end.returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "ok", "session_txt" => "duplicate-session", "account" => { "brokerage_account_id" => "DE1234" } }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: login_poller_headers

    assert_response :no_content
    item.reload
    assert_equal "new-login", item.pending_login_state
    assert_not_predicate item, :scheduled_for_deletion?
  end

  test "push login for an account already connected by another item is discarded" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :requires_update, pending_login_state: "pending-login"
    )
    provider = mock
    provider.expects(:complete_login).with(pending_login_b64: "pending-login").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "ok", "session_txt" => "duplicate-session", "account" => { "brokerage_account_id" => "DE1234" } }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, %(target="trade-republic-providers-panel")
    assert_includes response.body, I18n.t("trade_republic_items.duplicate_connection")
    item.reload
    assert_predicate item, :scheduled_for_deletion?
    assert_not item.session_configured?
    assert_nil item.pending_login_state
  end

  test "QR login for an account already connected by another item is discarded" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :requires_update, pending_login_state: "qr-pending"
    )
    provider = mock
    provider.stubs(:login_stage).returns("qr_pending")
    provider.expects(:poll_qr_login).with(pending_login_b64: "qr-pending").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "ok", "session_txt" => "duplicate-session", "account" => { "brokerage_account_id" => "DE1234" } }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :success
    assert_equal "duplicate_connection", JSON.parse(response.body).fetch("status")
    assert_equal I18n.t("trade_republic_items.duplicate_connection"), flash[:alert]
    item.reload
    assert_predicate item, :scheduled_for_deletion?
    assert_not item.session_configured?
    assert_predicate trade_republic_items(:configured_item).reload, :session_configured?
  end

  test "a login for an account another item already claimed before its first sync is treated as a duplicate" do
    other_item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :good, session_blob: "not-yet-synced", brokerage_account_id: "DE9999"
    )
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :requires_update, pending_login_state: "pending-login"
    )
    provider = mock
    provider.expects(:complete_login).with(pending_login_b64: "pending-login").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "ok", "session_txt" => "duplicate-session", "account" => { "brokerage_account_id" => "DE9999" } }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)

    post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, I18n.t("trade_republic_items.duplicate_connection")
    item.reload
    assert_predicate item, :scheduled_for_deletion?
    assert_nil item.brokerage_account_id
    assert_equal "DE9999", other_item.reload.brokerage_account_id
  end

  test "a race lost against a concurrent login for the same account is handled as a duplicate, not a server error" do
    # A real row for the account the concurrent winner just claimed, so the
    # unique index -- not a stub -- is what rejects this item's write below.
    families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :good, session_blob: "winner", brokerage_account_id: "DE1234"
    )
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :requires_update, pending_login_state: "pending-login"
    )
    provider = mock
    provider.expects(:complete_login).with(pending_login_b64: "pending-login").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "ok", "session_txt" => "session", "account" => { "brokerage_account_id" => "DE1234" } }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)
    # Force the early check to miss it, as a genuinely concurrent request
    # would (the winner's row exists, but not yet at the moment this request
    # checked) -- only the unique index catches it from here.
    TradeRepublicItemsController.any_instance.stubs(:duplicate_connection?).returns(false)

    post poll_login_trade_republic_item_url(item), headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, I18n.t("trade_republic_items.duplicate_connection")
    item.reload
    assert_predicate item, :scheduled_for_deletion?
    assert_nil item.brokerage_account_id
  end

  test "reconnecting an item to its own account is not treated as a duplicate" do
    item = trade_republic_items(:configured_item)
    item.update!(pending_login_state: "qr-pending", status: :requires_update)
    provider = mock
    provider.stubs(:login_stage).returns("qr_pending")
    provider.expects(:poll_qr_login).with(pending_login_b64: "qr-pending").returns(
      Provider::TradeRepublicClient::Result.new(
        data: { "status" => "ok", "session_txt" => "fresh-session", "account" => { "brokerage_account_id" => "DE1234" } }
      )
    )
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(provider)
    TradeRepublicItem.any_instance.stubs(:syncing?).returns(true)

    post poll_qr_login_trade_republic_item_url(item), headers: { "ACCEPT" => "application/json" }

    assert_response :success
    item.reload
    assert_predicate item, :good?
    assert_equal "fresh-session", item.session_blob
    assert_not item.scheduled_for_deletion?
  end

  private

    def login_poller_headers
      { "ACCEPT" => "text/vnd.turbo-stream.html", "X-Requested-With" => "XMLHttpRequest" }
    end

    def login_state(ids)
      Base64.strict_encode64(JSON.generate(ids.merge("session_blob" => "session=1")))
    end
end
