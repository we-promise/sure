require "test_helper"

class LunchflowItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "setup accounts renders German subtype options without English fallbacks" do
    ensure_tailwind_build
    @user.update!(locale: "de")

    get setup_accounts_lunchflow_item_url(lunchflow_items(:one))

    assert_response :success
    assert_select "title", text: "Lunch‑Flow-Konten einrichten"
    assert_select "option", text: "Untertyp auswählen"
    assert_select "option", text: "Typ auswählen"

    [
      "Nicht registriertes Anlagekonto",
      "FHSA (Sparkonto für den ersten Immobilienkauf)",
      "RDSP (registrierter Sparplan für Menschen mit Behinderung)",
      "DPSP (aufgeschobener Gewinnbeteiligungsplan)",
      "PRPP (gemeinschaftlicher registrierter Altersvorsorgeplan)",
      "LIF (lebenslanger Einkommensfonds)",
      "LRIF (gebundener Altersvorsorge-Einkommensfonds)",
      "PRIF (vorgeschriebener registrierter Altersvorsorge-Einkommensfonds)",
      "RLIF (beschränkter lebenslanger Einkommensfonds)",
      "Assurance Vie",
      "Eigenheimkredit",
      "Kreditlinie",
      "Unternehmenskredit"
    ].each do |label|
      assert_select "option", text: label
    end

    assert_select "option", text: "UGMA-Treuhandkonto"

    refute_includes response.body, "Select subtype"
    refute_includes response.body, "Select type"
    refute_includes response.body, "First Home Savings Account"
    refute_includes response.body, "UGMA Custodial Account"
  end

  test "setup accounts preserves the English title and placeholders" do
    ensure_tailwind_build
    @user.update!(locale: "en")

    get setup_accounts_lunchflow_item_url(lunchflow_items(:one))

    assert_response :success
    assert_select "title", text: "Set Up Lunch Flow Accounts"
    assert_select "option", text: "Select subtype"
    assert_select "option", text: "Select type"
  end

  test "account setup localizes an unexpected error in German" do
    @user.update!(locale: "de")
    lunchflow_account = lunchflow_accounts(:investment_account)
    Account.stubs(:create_and_sync).raises(StandardError, "Synthetic failure")

    post complete_account_setup_lunchflow_item_url(lunchflow_items(:one)), params: {
      account_types: { lunchflow_account.id => "Investment" },
      account_subtypes: { lunchflow_account.id => "brokerage" }
    }

    assert_redirected_to accounts_path
    assert_equal "Konten konnten nicht angelegt werden: Ein unerwarteter Fehler ist aufgetreten. Versuch es noch einmal.", flash[:alert]
  end

  test "account setup preserves the unexpected error in English" do
    @user.update!(locale: "en")
    lunchflow_account = lunchflow_accounts(:investment_account)
    Account.stubs(:create_and_sync).raises(StandardError, "Synthetic failure")

    post complete_account_setup_lunchflow_item_url(lunchflow_items(:one)), params: {
      account_types: { lunchflow_account.id => "Investment" },
      account_subtypes: { lunchflow_account.id => "brokerage" }
    }

    assert_redirected_to accounts_path
    assert_equal "Failed to create accounts: An unexpected error occurred", flash[:alert]
  end

  test "invalid non-Turbo create redirects instead of rendering a missing template" do
    assert_no_difference "LunchflowItem.count" do
      post lunchflow_items_url, params: {
        lunchflow_item: {
          name: "Invalid Lunchflow connection",
          api_key: ""
        }
      }
    end

    assert_redirected_to accounts_path
    assert_match "Api key can't be blank", flash[:alert]
  end
end
