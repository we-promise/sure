require "application_system_test_case"

class MoomooSetupTest < ApplicationSystemTestCase
  setup do
    users(:family_admin).family.update!(auto_sync_on_login: false)
    @item = moomoo_items(:connected_item)
    @item.moomoo_accounts.destroy_all
    @sync = @item.syncs.create!(status: "syncing", syncing_at: Time.current)
    sign_in users(:family_admin)
  end

  test "the setup dialog offers the accounts once the first sync finishes, without reopening" do
    visit setup_accounts_moomoo_item_path(@item)
    assert_selector "dialog[open] turbo-frame#moomoo-setup-accounts [data-controller=polling]"
    page.execute_script("document.querySelector('dialog[open]').dataset.original = 'true'")

    @item.moomoo_accounts.create!(moomoo_account_id: "3333", name: "moomoo SG ••3333", currency: "SGD",
                                  account_kind: "securities", enable_markets: [ 6, 2, 1 ])
    @sync.update!(status: "completed", completed_at: Time.current)

    assert_selector "dialog[open][data-original] input[name='account_ids[]']", visible: :all, wait: 10
    assert_no_selector "[data-controller=polling]"
    assert_text "moomoo SG ••3333"
  end

  # The first rows exist before the sync has split the account by currency.
  test "the setup dialog keeps refreshing until the sync that is adding accounts finishes" do
    visit setup_accounts_moomoo_item_path(@item)
    assert_selector "dialog[open] turbo-frame#moomoo-setup-accounts [data-controller=polling]"
    page.execute_script("document.querySelector('dialog[open]').dataset.original = 'true'")

    primary = @item.moomoo_accounts.create!(moomoo_account_id: "3333", name: "moomoo SG ••3333 (SGD cash)", currency: "SGD",
                                            role: "cash", account_kind: "securities", enable_markets: [ 6, 2 ])

    assert_text "moomoo SG ••3333 (SGD cash)", wait: 10
    assert_selector "dialog[open][data-original] #moomoo-setup-still-syncing[data-controller=polling]"
    assert_selector "button[type=submit][disabled]", text: I18n.t("moomoo_items.setup_accounts.buttons.create_selected_accounts")

    @item.moomoo_accounts.create!(moomoo_account_id: "3333", primary_moomoo_account: primary, name: "moomoo SG ••3333 (USD stocks)",
                                  currency: "USD", role: "stocks", account_kind: "securities")
    @sync.update!(status: "completed", completed_at: Time.current)

    assert_text "moomoo SG ••3333 (USD stocks)", wait: 10
    assert_no_selector "[data-controller=polling]"
    assert_selector "dialog[open][data-original] button[type=submit]:not([disabled])", text: I18n.t("moomoo_items.setup_accounts.buttons.create_selected_accounts")
  end
end
