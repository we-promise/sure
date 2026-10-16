require "application_system_test_case"

class TradeRepublicQrLoginTest < ApplicationSystemTestCase
  include TradeRepublicSessionTestHelper

  setup do
    sign_in users(:family_admin)
    @item = trade_republic_items(:configured_item)
    @item.update!(session_blob: trade_republic_session_blob(expires_at: 1.minute.ago))

    pending = Provider::TradeRepublicClient::Result.new(data: {
      "status" => "pending",
      "pending_login_b64" => "pending",
      "qr_code_payload" => "https://example.com/qr"
    })
    Provider::TradeRepublicClient.any_instance.stubs(:initiate_qr_login).returns(pending)
    Provider::TradeRepublicClient.any_instance.stubs(:poll_qr_login).returns(pending)
  end

  test "a QR login on Accounts can be cancelled and started again" do
    visit accounts_path

    within card do
      click_on qr_login
      assert_selector ".qrcode svg"
      assert_button qr_cancel

      click_on qr_cancel
      # The button is enabled again only once the server confirmed the cancel.
      assert_button qr_login
      assert_no_selector ".qrcode svg"
    end
    assert_nil @item.reload.pending_login_state

    within card do
      click_on qr_login
      assert_selector ".qrcode svg"
      assert_button qr_cancel

      # Stop the poller so no request is in flight when the test ends.
      click_on qr_cancel
      assert_button qr_login
    end
  end

  test "cancelling a QR login while it is still starting leaves no login behind" do
    pending = Provider::TradeRepublicClient::Result.new(data: { "status" => "pending", "pending_login_b64" => "pending" })
    # Trade Republic answers slowly, so the cancel is sent while the login starts.
    Provider::TradeRepublicClient.any_instance.stubs(:initiate_qr_login).with { sleep 1.5 }.returns(pending)

    visit accounts_path

    within card do
      click_on qr_login
      click_on qr_cancel
      assert_button qr_login, disabled: false, wait: 10
    end
    # Give a start that was not waited for the time to store its login.
    sleep 2
    assert_nil @item.reload.pending_login_state
  end

  test "cancelling a QR login that was already running when the page loaded" do
    @item.update!(pending_login_state: "pending", status: :requires_update)
    Provider::TradeRepublicClient.any_instance.stubs(:login_stage).returns("qr_pending")

    visit accounts_path

    within card do
      assert_selector ".qrcode svg"
      click_on qr_cancel
      assert_button qr_login
      assert_no_selector ".qrcode svg"
    end
    assert_nil @item.reload.pending_login_state
  end

  test "cancelling a running QR login in Settings refreshes its connection" do
    @item.update!(pending_login_state: "pending", status: :requires_update)
    Provider::TradeRepublicClient.any_instance.stubs(:login_stage).returns("qr_pending")

    visit settings_providers_path
    find("summary", text: "Trade Republic").click

    within "##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}" do
      assert_text panel_t("awaiting_confirmation")
      click_on qr_cancel
      assert_text panel_t("requires_update")
      assert_button qr_login
    end
    assert_nil @item.reload.pending_login_state
  end

  test "a connection runs either its QR login or its PIN login, not both" do
    visit settings_providers_path
    find("summary", text: "Trade Republic").click

    within "##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}" do
      assert_no_field "trade_republic_item[pin]"
      click_on panel_t("pin_login")
      assert_field "trade_republic_item[pin]"
      assert_no_button qr_login
      assert_no_button panel_t("pin_login"), exact: true
      click_on panel_t("pin_cancel")
      assert_no_field "trade_republic_item[pin]"
      assert_button panel_t("pin_login")

      click_on qr_login
      assert_selector ".qrcode svg"
      assert_no_button panel_t("pin_login")
      click_on qr_cancel
    end

    # The cancel replaces the card, so each check looks it up again.
    assert_selector "#{connection_card} button:not([disabled])", exact_text: panel_t("pin_login")
    assert_selector "#{connection_card} button:not([disabled])", exact_text: qr_login
  end

  test "the PIN login comes back only once a QR cancel is done" do
    visit settings_providers_path
    find("summary", text: "Trade Republic").click
    hold_qr_cancel

    within "##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}" do
      click_on qr_login
      assert_selector ".qrcode svg"
      click_on qr_cancel
      # The cancel could still clear a PIN login started now.
      assert_button qr_login, disabled: true
      assert_no_button panel_t("pin_login"), exact: true
    end

    page.execute_script("window.releaseQrCancel()")

    # The cancel replaces the card, so each check looks it up again.
    assert_selector "#{connection_card} button:not([disabled])", exact_text: panel_t("pin_login")
    assert_selector "#{connection_card} button:not([disabled])", exact_text: qr_login
  end

  test "a failed QR login keeps the PIN login hidden until it is cancelled" do
    Provider::TradeRepublicClient.any_instance.stubs(:poll_qr_login).raises(Provider::TradeRepublicClient::Error, "boom")

    visit settings_providers_path
    find("summary", text: "Trade Republic").click

    within "##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}" do
      click_on qr_login
      assert_text panel_t("qr_error")
      # The login may still be pending, so its button cancels it first.
      assert_button qr_cancel
      assert_no_button panel_t("pin_login"), exact: true
      click_on qr_cancel
    end

    assert_selector "#{connection_card} button:not([disabled])", exact_text: panel_t("pin_login")
    assert_nil @item.reload.pending_login_state
  end

  test "a QR login replaced by a newer login shows that login instead of offering to cancel it" do
    item = @item
    # Another tab starts a newer login while this tab's poll waits.
    Provider::TradeRepublicClient.any_instance.stubs(:poll_qr_login).with { |**| item.update_columns(pending_login_state: "newer"); true }
      .returns(Provider::TradeRepublicClient::Result.new(data: { "status" => "pending", "pending_login_b64" => "pending" }))

    visit settings_providers_path
    find("summary", text: "Trade Republic").click
    page.execute_script("document.body.dataset.beforeReload = 'true'")

    within("##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}") { click_on qr_login }

    # The page reloads with the newer login's state, and nothing cancels it.
    assert_no_selector "body[data-before-reload]"
    assert_no_selector "#{connection_card} .qrcode svg"
    assert_no_button qr_cancel
    assert_equal "newer", @item.reload.pending_login_state
  end

  test "a failed QR cancel keeps the PIN login hidden until a retried cancel succeeds" do
    visit settings_providers_path
    find("summary", text: "Trade Republic").click
    page.execute_script(<<~JS)
      const fetch = window.fetch;
      window.failQrCancel = true;
      window.fetch = (url, options) => window.failQrCancel && String(url).includes("cancel_qr_login")
        ? Promise.resolve(new Response("", { status: 500 }))
        : fetch(url, options);
    JS

    within "##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}" do
      click_on qr_login
      assert_selector ".qrcode svg"
      click_on qr_cancel
      assert_text panel_t("qr_error")
      assert_button qr_cancel, disabled: false
      assert_no_button panel_t("pin_login"), exact: true
    end

    page.execute_script("window.failQrCancel = false")
    within("##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}") { click_on qr_cancel }

    # The cancel replaces the card, so each check looks it up again.
    assert_selector "#{connection_card} button:not([disabled])", exact_text: panel_t("pin_login")
    assert_nil @item.reload.pending_login_state
  end

  test "a new connection's PIN login takes the place of Add a connection, like its QR login" do
    visit settings_providers_path
    find("summary", text: "Trade Republic").click

    within "##{TradeRepublic::NewConnectionComponent::DOM_ID}" do
      assert_text panel_t("add_connection")
      click_on panel_t("pin_login")
      assert_field "trade_republic_pending_connection[phone_number]"
      assert_no_text panel_t("add_connection")
      assert_no_button qr_login
      assert_no_button panel_t("pin_login")

      click_on panel_t("cancel_login")
      assert_no_field "trade_republic_pending_connection[phone_number]"
      assert_text panel_t("add_connection")
      assert_button qr_login
    end
    assert_no_selector "#drawer dialog"
  end

  private

    def connection_card
      "##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}"
    end

    # Holds the browser's QR cancel request until releaseQrCancel() runs.
    def hold_qr_cancel
      page.execute_script(<<~JS)
        const fetch = window.fetch;
        window.fetch = (url, options) => {
          if (!String(url).includes("cancel_qr_login")) return fetch(url, options);
          return new Promise((resolve) => {
            window.releaseQrCancel = () => resolve(fetch(url, options));
          });
        };
      JS
    end

    def card
      "##{ActionView::RecordIdentifier.dom_id(@item)}"
    end

    def panel_t(key) = I18n.t("settings.providers.trade_republic_panel.#{key}")
    def qr_login = panel_t("qr_login")
    def qr_cancel = panel_t("qr_cancel")
end
