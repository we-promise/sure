require "application_system_test_case"

class AccountProviderReconnectTest < ApplicationSystemTestCase
  setup do
    @account = accounts(:investment)
    @item = trade_republic_items(:configured_item)
    @item.update!(session_expires_at: 1.minute.ago)
    @account.account_providers.create!(provider: trade_republic_accounts(:main_account))

    sign_in users(:family_admin)
  end

  test "the account page links an expired connection to its card below the page header" do
    visit account_path(@account)

    within "[data-testid='account-health-status']" do
      assert_text I18n.t("accounts.health_status.provider_reconnect.message", provider: @item.institution_display_name)
      click_link I18n.t("accounts.health_status.provider_reconnect.link")
    end

    assert_current_path accounts_path
    card = find("##{ActionView::RecordIdentifier.dom_id(@item)}")
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
