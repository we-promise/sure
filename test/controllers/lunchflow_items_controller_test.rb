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

  test "account selection localizes an unexpected error in German" do
    @user.update!(locale: "de")
    Provider::LunchflowAdapter.stubs(:build_provider).raises(StandardError, "Synthetic failure")

    get select_accounts_lunchflow_items_url

    assert_response :success
    assert_includes response.body, "Ein unerwarteter Fehler ist aufgetreten. Versuch es später noch einmal."
    refute_includes response.body, "An unexpected error occurred. Please try again later."
    assert I18n.exists?("lunchflow_items.api_error.unexpected_error", :de, fallback: false)
    assert_equal "An unexpected error occurred. Please try again later.",
                 I18n.t("lunchflow_items.api_error.unexpected_error", locale: :en, fallback: false)
  end

  test "existing-account selection localizes an unexpected error in German" do
    @user.update!(locale: "de")
    Provider::LunchflowAdapter.stubs(:build_provider).raises(StandardError, "Synthetic failure")

    get select_existing_account_lunchflow_items_url(account_id: accounts(:depository).id)

    assert_response :success
    assert_includes response.body, "Ein unerwarteter Fehler ist aufgetreten. Versuch es später noch einmal."
    refute_includes response.body, "An unexpected error occurred. Please try again later."
  end

  test "account selection preserves provider error details" do
    @user.update!(locale: "de")
    Provider::LunchflowAdapter.stubs(:build_provider).raises(
      Provider::Lunchflow::LunchflowError,
      "Provider-specific failure"
    )

    get select_accounts_lunchflow_items_url

    assert_response :success
    assert_includes response.body, "Provider-specific failure"
    refute_includes response.body, "Ein unerwarteter Fehler ist aufgetreten. Versuch es später noch einmal."
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

  # link_existing_account looks the Lunchflow account up by its upstream
  # account_id, while the shared tests post the record id, so the two are equal.
  include ProviderLinkAuthorizationTests
  provider_link_authorization_tests(
    select_url: :select_existing_account_lunchflow_items_url,
    link_url: :link_existing_account_lunchflow_items_url,
    target: ->(owner) {
      owner.family.accounts.create!(owner: owner, name: "Manual Checking", balance: 0, currency: "USD",
                                    accountable: Depository.new)
    },
    provider_account: -> {
      id = SecureRandom.uuid
      lunchflow_items(:one).lunchflow_accounts.create!(id: id, account_id: id, name: "Lunchflow Checking",
                                                       currency: "USD")
    },
    provider_param: :lunchflow_account_id,
    prepare: -> {
      accounts = lunchflow_items(:one).lunchflow_accounts.reload.map do |lunchflow_account|
        { id: lunchflow_account.account_id, name: lunchflow_account.name, currency: "USD" }
      end
      Provider::LunchflowAdapter.stubs(:build_provider).returns(stub(get_accounts: { accounts: accounts }))
    }
  )
end
