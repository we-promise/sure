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

  test "cancelling a running QR login in Settings brings back the credentials form" do
    @item.update!(pending_login_state: "pending", status: :requires_update)
    Provider::TradeRepublicClient.any_instance.stubs(:login_stage).returns("qr_pending")

    visit settings_providers_path
    find("summary", text: "Trade Republic").click

    within "##{TradeRepublic::ConnectionCardComponent.dom_id_for(@item)}" do
      assert_no_field "trade_republic_item[phone_number]"
      click_on qr_cancel
      assert_field "trade_republic_item[phone_number]"
      assert_button qr_login
    end
    assert_nil @item.reload.pending_login_state
  end

  private

    def card
      "##{ActionView::RecordIdentifier.dom_id(@item)}"
    end

    def qr_login = I18n.t("settings.providers.trade_republic_panel.qr_login")
    def qr_cancel = I18n.t("settings.providers.trade_republic_panel.qr_cancel")
end
