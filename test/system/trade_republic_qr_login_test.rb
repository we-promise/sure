require "application_system_test_case"

class TradeRepublicQrLoginTest < ApplicationSystemTestCase
  include TradeRepublicSessionTestHelper

  setup do
    sign_in users(:family_admin)
    @item = trade_republic_items(:configured_item)
    @item.update!(session_blob: trade_republic_session_blob(expires_at: 1.minute.ago))

    pending = Provider::TradeRepublicClient::Result.new(data: { "status" => "pending", "pending_login_b64" => "pending" })
    Provider::TradeRepublicClient.any_instance.stubs(:initiate_qr_login).returns(pending)
    Provider::TradeRepublicClient.any_instance.stubs(:poll_qr_login).returns(pending)
  end

  test "the QR login button on Accounts switches between starting and cancelling" do
    login = I18n.t("settings.providers.trade_republic_panel.qr_login")
    cancel = I18n.t("settings.providers.trade_republic_panel.qr_cancel")

    visit accounts_path

    within "##{ActionView::RecordIdentifier.dom_id(@item)}" do
      click_on login
      assert_button cancel

      click_on cancel
      assert_button login
      assert_no_text I18n.t("settings.providers.trade_republic_panel.qr_instruction")

      click_on login
      assert_button cancel
    end
  end
end
