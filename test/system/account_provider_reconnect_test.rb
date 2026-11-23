require "application_system_test_case"

class AccountProviderReconnectTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "an expired connection links an admin to bank sync, where it needs attention" do
    account = accounts(:investment)
    item = trade_republic_items(:configured_item)
    item.update!(session_expires_at: 1.minute.ago)
    account.account_providers.create!(provider: trade_republic_accounts(:main_account))

    visit account_path(account)

    within "[data-testid='account-health-status']" do
      assert_text I18n.t("accounts.health_status.provider_reconnect.message", provider: item.institution_display_name)
      click_link I18n.t("accounts.health_status.provider_reconnect.link_bank_sync")
    end

    assert_current_path settings_providers_path
    assert_selector "#trade-republic-connection"
  end

  test "a Plaid connection links to its card on the accounts page, below the page header" do
    account = accounts(:connected)
    item = plaid_items(:one)
    item.update!(status: :requires_update)

    visit account_path(account)

    within "[data-testid='account-health-status']" do
      click_link I18n.t("accounts.health_status.provider_reconnect.link_accounts")
    end

    assert_current_path accounts_path
    card = find("##{ActionView::RecordIdentifier.dom_id(item)}")
    header_bottom = page.evaluate_script("document.querySelector('[data-controller=settings-scroll] > .sticky').getBoundingClientRect().bottom")

    # Scrolled to the card, which starts just below the sticky header rather than under it.
    assert wait_until { card.evaluate_script("this.getBoundingClientRect().top").between?(header_bottom, header_bottom + 40) },
           "expected the connection card to start just below the page header"
  end

  private
    def wait_until
      deadline = Time.current + Capybara.default_max_wait_time
      loop do
        return true if yield
        return false if Time.current > deadline
        sleep 0.1
      end
    end
end
