require "test_helper"

# The bank sync drawers follow the Up panel: setup steps come from the shared
# setup_steps partial, messages are DS::Alerts and item actions are DS::Buttons.
class Settings::ProviderPanelsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "Wise, Brex and Redbark list their setup steps in the shared partial" do
    %w[wise brex redbark].each do |provider_key|
      get connect_form_settings_providers_path(provider_key: provider_key)

      assert_response :success
      assert_select "turbo-frame##{provider_key}-connect-form p", { text: I18n.t("settings.providers.setup_steps.eyebrow") }, provider_key
    end
  end

  test "Wise, Brex and Redbark show a rejected save in an error alert" do
    patch wise_item_url(wise_items(:one)), params: { wise_item: { name: "" } }, headers: { "Turbo-Frame" => "wise-providers-panel" }
    assert_error_alert "wise-providers-panel"

    post brex_items_url, params: { brex_item: { name: "Brex", token: "" } }, headers: { "Turbo-Frame" => "brex-providers-panel" }
    assert_error_alert "brex-providers-panel"

    post redbark_items_url, params: { redbark_item: { api_key: "" } }, headers: { "Turbo-Frame" => "redbark-providers-panel" }
    assert_error_alert "redbark-providers-panel"
  end

  test "provider warnings are titled alerts" do
    TradeRepublicItem.stubs(:encryption_ready?).returns(false)

    { "trade_republic" => "settings.providers.trade_republic_panel.encryption_warning.title",
      "kraken" => "settings.providers.kraken_panel.read_only_title",
      "coinspot" => "settings.providers.coinspot_panel.read_only_title" }.each do |provider_key, title_key|
      get connect_form_settings_providers_path(provider_key: provider_key)

      assert_response :success
      assert_select "turbo-frame##{provider_key}-connect-form p", { text: titled_alert(:warning, title_key) }, provider_key
    end

    get new_wallet_onchain_wallet_items_path
    assert_response :success
    assert_select "p", text: titled_alert(:info, "settings.providers.onchain_wallet_panel.keyless_title")
  end

  test "sync and disconnect actions are named DS buttons" do
    family = families(:dylan_family)
    CoinbaseItem.create!(family: family, name: "Coinbase", api_key: "key", api_secret: "secret")
    EnableBankingItem.create!(family: family, name: "Live", country_code: "FI", application_id: "app",
                              client_certificate: "cert", session_id: "live", session_expires_at: 1.day.from_now)
    EnableBankingItem.create!(family: family, name: "Expired", country_code: "FI", application_id: "app",
                              client_certificate: "cert", session_id: "expired", session_expires_at: 1.day.ago)

    %w[binance brex coinbase enable_banking kraken mercury].each do |provider_key|
      get connect_form_settings_providers_path(provider_key: provider_key)

      assert_response :success
      buttons = css_select("turbo-frame##{provider_key}-connect-form button")
      assert buttons.any?, "#{provider_key} renders no buttons"
      buttons.each do |button|
        assert (button["aria-label"].presence || button.text.squish.presence), "#{provider_key} has a button without a name: #{button.to_html}"
        assert_includes button["class"].to_s.split, "focus-ring", "#{provider_key} has a button without a focus ring: #{button.to_html}"
      end
      assert_select "turbo-frame##{provider_key}-connect-form button[data-turbo-confirm]", { minimum: 1 }, "#{provider_key} disconnects without confirming"
    end
  end

  private
    # DS::Alert prefixes its text with the variant for screen readers ("Error: …").
    def titled_alert(variant, title_key)
      /#{I18n.t("ds.alert.variants.#{variant}")}:\s*#{Regexp.escape(I18n.t(title_key))}/
    end

    def assert_error_alert(target)
      assert_response :unprocessable_entity
      assert_select "turbo-stream[target=#{target}] template p", text: /\A\s*#{I18n.t("ds.alert.variants.error")}:\s+\S/
    end
end
