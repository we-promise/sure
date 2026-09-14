require "application_system_test_case"

# Browser coverage for the open-banking.io connect -> link -> sync journey.
#
# This is the first end-to-end coverage of a provider's linking flow in this repo: the one
# existing provider system test covers the settings listing only, and no provider has a test
# that clicks "Link with ...". That gap is not academic -- four bugs shipped through unit and
# controller review because they are invisible below the browser:
#
#   * the provider was missing from the account picker entirely
#   * clicking it answered a redirect to a page with no <turbo-frame id="modal">, so Turbo
#     discarded the response and the modal silently closed
#   * Disconnect moved the item out of `active`, re-rendering a panel with no matching frame,
#     so the connection stayed on screen
#   * a malformed credentials paste answered 422-with-redirect, whose body is empty, so
#     Turbo rendered nothing at all
#
# Every one of those returned a *correct* HTTP status. A controller test asserting
# `assert_response :redirect` passes against all four -- and one of mine did exactly that,
# pinning the bug as intended behaviour. Only a browser sees that nothing happened.
class OpenBankingIoItemsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    login_as @user
  end

  def create_connection(name: "My Bank")
    OpenBankingIoItem.create!(
      family: @family, name: name,
      api_base_url: "https://open-banking.io", api_key: "k", private_key: "p"
    )
  end

  def link_with_open_banking_io
    I18n.t("accounts.new.method_selector.link_with_provider",
           provider: I18n.t("providers.open_banking_io.name"))
  end

  # Opens the connect drawer for the not-yet-configured provider.
  def open_connect_drawer
    find("a[data-turbo-frame='drawer']", text: I18n.t("providers.open_banking_io.name")).click
    assert_selector "dialog[open]"
  end

  # A configured connection lives in a collapsed <details>; expand it before asserting.
  def expand_connection_section
    find("details", text: "open-banking.io").find("summary").click
    assert_selector "details[open]", text: "open-banking.io"
  end

  # Each connection inside the panel is itself a collapsed DS::Disclosure, so its controls
  # (Sync, Disconnect, the credential form) need a second expand.
  def expand_connection(name)
    within("details[open]", text: "open-banking.io") do
      find("summary", text: name).click
    end
  end

  def credentials_json
    {
      "apiBaseUrl" => "https://open-banking.io",
      "apiKey" => "paste-api-key",
      "encryptionKey" => { "privateKey" => "paste-private-key" }
    }.to_json
  end

  # === DISCOVERABILITY ===

  test "the provider is offered in the account picker before any connection exists" do
    assert_equal 0, @family.open_banking_io_items.count

    visit new_account_path
    click_on Depository.new.singular_display_name

    assert_text link_with_open_banking_io
  end

  # The bug: this used to answer a 302 to a frameless page, which Turbo threw away -- the
  # modal just vanished with no message and no navigation.
  test "choosing it with no connection explains the setup inside the modal" do
    visit new_account_path
    click_on Depository.new.singular_display_name
    click_on link_with_open_banking_io

    assert_text I18n.t("open_banking_io_items.setup_required.title")
    assert_text I18n.t("open_banking_io_items.setup_required.credentials_not_configured")
    assert_selector "a", text: I18n.t("open_banking_io_items.setup_required.go_to_provider_settings")
  end

  test "the setup dialog leads to provider settings" do
    visit new_account_path
    click_on Depository.new.singular_display_name
    click_on link_with_open_banking_io
    click_on I18n.t("open_banking_io_items.setup_required.go_to_provider_settings")

    assert_current_path settings_providers_path
  end

  # === CONNECTING ===

  test "pasting a credentials bundle creates the connection" do
    SyncJob.stubs(:perform_later)
    visit settings_providers_path

    open_connect_drawer
    fill_in I18n.t("open_banking_io_items.provider_panel.credentials_label"), with: credentials_json
    click_on I18n.t("open_banking_io_items.provider_panel.add_connection")

    assert_text I18n.t("open_banking_io_items.create.success")
    assert_equal 1, @family.open_banking_io_items.count
  end

  # The bug: a 422 redirect has an empty body, and Turbo renders nothing for an empty failed
  # submission -- so a malformed paste did literally nothing, on the very first thing a new
  # user does with this provider.
  test "a malformed credentials paste tells the user why" do
    visit settings_providers_path

    open_connect_drawer
    fill_in I18n.t("open_banking_io_items.provider_panel.credentials_label"), with: "{not json"
    click_on I18n.t("open_banking_io_items.provider_panel.add_connection")

    assert_text I18n.t("open_banking_io_items.provider_panel.credentials_invalid")
    assert_equal 0, @family.open_banking_io_items.count
  end

  test "a credentials bundle pointing off open-banking.io is rejected" do
    visit settings_providers_path
    hostile = { "apiBaseUrl" => "https://open-banking.io.evil.com", "apiKey" => "k",
                "encryptionKey" => { "privateKey" => "p" } }.to_json

    open_connect_drawer
    fill_in I18n.t("open_banking_io_items.provider_panel.credentials_label"), with: hostile
    click_on I18n.t("open_banking_io_items.provider_panel.add_connection")

    assert_text I18n.t("open_banking_io_items.provider_panel.credentials_invalid_url")
    assert_equal 0, @family.open_banking_io_items.count
  end

  # === LINKING ===

  test "a configured connection takes the picker straight to account selection" do
    item = create_connection
    item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR", current_balance: 250)
    OpenBankingIoItem.any_instance.stubs(:refresh_accounts_from_provider!).returns(nil)

    visit new_account_path
    click_on Depository.new.singular_display_name
    click_on I18n.t("accounts.new.method_selector.link_with_provider", provider: item.name)

    assert_text "Everyday"
  end

  test "linking an account creates it and returns to accounts" do
    SyncJob.stubs(:perform_later)
    item = create_connection
    item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR", current_balance: 250)
    OpenBankingIoItem.any_instance.stubs(:refresh_accounts_from_provider!).returns(nil)

    visit new_account_path
    click_on Depository.new.singular_display_name
    click_on I18n.t("accounts.new.method_selector.link_with_provider", provider: item.name)
    check "Everyday"
    click_on I18n.t("open_banking_io_items.select_accounts.link_accounts")

    assert_current_path accounts_path
    assert @family.accounts.exists?(name: "Everyday")
  end

  # The bug: these redirected back to a picker rendered `layout: false` -- a bare frame with
  # no <html>, CSS or JS, so the dialog never opened and the user got a blank white page.
  test "submitting with nothing selected does not land on a blank page" do
    item = create_connection
    item.open_banking_io_accounts.create!(account_id: "a1", name: "Everyday", currency: "EUR")
    OpenBankingIoItem.any_instance.stubs(:refresh_accounts_from_provider!).returns(nil)

    visit new_account_path
    click_on Depository.new.singular_display_name
    click_on I18n.t("accounts.new.method_selector.link_with_provider", provider: item.name)
    click_on I18n.t("open_banking_io_items.select_accounts.link_accounts")

    # A real page, not a naked turbo-frame fragment.
    assert_selector "body"
    assert_text I18n.t("open_banking_io_items.link_accounts.no_accounts_selected")
  end

  # === MANAGING ===

  test "a connection appears under Your connections with its status" do
    create_connection(name: "Sparekassen")

    visit settings_providers_path
    expand_connection_section

    within("details[open]", text: "open-banking.io") do
      assert_text "Sparekassen"
    end
  end

  # The bug: Disconnect moved the item out of `active`, so the panel re-rendered as an
  # "Available" card containing no such frame -- Turbo discarded it and the connection stayed
  # on screen until a manual reload.
  test "disconnecting removes the connection from the panel" do
    item = create_connection(name: "Sparekassen")
    OpenBankingIoItem.any_instance.stubs(:unlink_all!).returns([])
    DestroyJob.stubs(:perform_later)

    visit settings_providers_path
    expand_connection_section
    expand_connection("Sparekassen")
    click_on I18n.t("open_banking_io_items.provider_panel.disconnect")

    # data-turbo-confirm is overridden by the app's own #confirm-dialog, not window.confirm.
    within("#confirm-dialog") do
      click_button I18n.t("layouts.shared.confirm_dialog.confirm")
    end

    assert_no_text "Sparekassen"
    assert item.reload.scheduled_for_deletion
  end

  test "a connection with unlinked accounts prompts an admin to finish setup" do
    item = create_connection
    item.open_banking_io_accounts.create!(account_id: "a1", name: "Unlinked", currency: "EUR")

    visit accounts_path

    assert_text I18n.t("open_banking_io_items.open_banking_io_item.setup_needed")
  end
end
