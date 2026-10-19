require "test_helper"

class TradeRepublicItemsLocalizationTest < ActiveSupport::TestCase
  SETUP_ACCOUNT_TRANSLATIONS = {
    "dialog_title" => "Dein Trade-Republic-Konto einrichten",
    "info_box.title" => "Trade-Republic-Import",
    "info_box.items.item_1" => "Aktuelle Positionen mit Kursen und Stückzahlen",
    "info_box.items.item_2" => "Ausgeführte Käufe und Verkäufe",
    "info_box.items.item_3" => "Ein- und Auszahlungen sowie Zinsgutschriften",
    "status.fetching_accounts" => "Konto wird von Trade Republic abgerufen …",
    "status.no_accounts_found_title" => "Kein Konto gefunden.",
    "status.no_accounts_found_description" => "Sure hat kein Trade-Republic-Konto gefunden. Prüf, ob deine Trade-Republic-Sitzung noch gültig ist.",
    "available_accounts.title" => "Verfügbares Konto",
    "available_accounts.account_summary" => "%{account_type} • Saldo: %{balance}",
    "available_accounts.account_id" => "Konto-ID: %{account_id}",
    "link_existing.description" => "Alternativ kannst du das gefundene Trade-Republic-Konto mit einem bestehenden manuellen Investmentkonto verknüpfen.",
    "link_existing.manual_account_option" => "%{name} (%{balance})",
    "link_existing.select_prompt" => "Konto auswählen …",
    "linked_accounts.title" => "Bereits verknüpft",
    "linked_accounts.linked_to_html" => "Verknüpft mit: %{account}",
    "buttons.back_to_settings" => "Zurück zu den Einstellungen",
    "buttons.create_selected_accounts" => "Ausgewählte Konten anlegen"
  }.freeze

  test "German account setup copy matches the expected translations" do
    SETUP_ACCOUNT_TRANSLATIONS.each do |key, expected|
      full_key = "trade_republic_items.setup_accounts.#{key}"

      assert I18n.exists?(full_key, :de, fallback: false), "de is missing #{full_key}"
      assert_equal expected, I18n.t(full_key, locale: :de, resolve: false)
    end
  end
end

class TradeRepublicItemsSetupAccountsLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @user.update!(locale: "de")
    @item = trade_republic_items(:configured_item)
  end

  test "German account setup renders available, linkable, and linked accounts" do
    trade_republic_accounts(:main_account).ensure_account_provider!(accounts(:investment))

    get setup_accounts_trade_republic_item_url(@item)

    assert_response :success
    assert_setup_copy "dialog_title"
    assert_setup_copy "info_box.title"
    assert_setup_copy "available_accounts.title"
    assert_setup_copy "buttons.create_selected_accounts"
    assert_setup_copy "link_existing.select_prompt"
    assert_setup_copy "linked_accounts.title"
    assert_setup_copy "linked_accounts.linked_to_html", account: ""
  end

  test "German account setup renders the waiting state" do
    @item.trade_republic_accounts.destroy_all
    TradeRepublicItem.any_instance.stubs(:syncing?).returns(true)

    get setup_accounts_trade_republic_item_url(@item)

    assert_response :success
    assert_setup_copy "status.fetching_accounts"
  end

  test "German account setup renders the empty state" do
    @item.trade_republic_accounts.destroy_all
    @item.syncs.create!(status: "completed", completed_at: Time.current)
    TradeRepublicItem.any_instance.stubs(:syncing?).returns(false)
    TradeRepublicItem.any_instance.stubs(:sync_later)

    get setup_accounts_trade_republic_item_url(@item)

    assert_response :success
    assert_setup_copy "status.no_accounts_found_title"
    assert_setup_copy "status.no_accounts_found_description"
    assert_setup_copy "buttons.back_to_settings"
  end

  private

    def assert_page_includes(text)
      assert_includes response.body, ERB::Util.html_escape(text)
    end

    def assert_setup_copy(key, **interpolations)
      template = TradeRepublicItemsLocalizationTest::SETUP_ACCOUNT_TRANSLATIONS.fetch(key)
      assert_page_includes(template % interpolations)
    end
end
