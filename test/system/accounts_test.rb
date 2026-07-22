require "application_system_test_case"

class AccountsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    Family.any_instance.stubs(:get_link_token).returns("test-link-token")

    visit root_url
    open_new_account_modal
  end

  test "can create depository account" do
    assert_account_created("Depository")
  end

  test "can create investment account" do
    assert_account_created("Investment")
  end

  test "can create insurance account" do
    assert_account_created "Insurance" do
      select "Life Insurance", from: "Insurance type"
      fill_in "Policy number", with: "POL-123"
      fill_in "account[accountable_attributes][coverage_amount]", with: 500000
      fill_in "account[accountable_attributes][premium_amount]", with: 150
      select "Monthly", from: "Premium frequency"
    end
  end

  test "can create crypto account" do
    assert_account_created("Crypto")
  end

  test "can create property account" do
    # Step 1: Select property type and enter basic details
    click_link "Property"

    account_name = "[system test] Property Account"
    fill_in "Name*", with: account_name
    select "Single Family Home", from: "Property type*"
    fill_in "Year Built (optional)", with: 2005
    fill_in "Area (optional)", with: 2250

    click_button "Next"

    # Step 2: Enter balance information
    assert_text "Value"
    fill_in "account[balance]", with: 500000
    click_button "Next"

    # Step 3: Enter address information
    assert_text "Address"
    fill_in "Address Line 1", with: "123 Main St"
    fill_in "City", with: "San Francisco"
    fill_in "State/Region", with: "CA"
    fill_in "Postal Code", with: "94101"
    fill_in "Country", with: "US"

    click_button "Save"

    # Verify account was created and is now active
    assert_text account_name

    created_account = Account.order(:created_at).last
    assert_equal "active", created_account.status
    assert_equal 500000, created_account.balance
    assert_equal "123 Main St", created_account.property.address.line1
    assert_equal "San Francisco", created_account.property.address.locality
  end

  test "can create vehicle account" do
    assert_account_created "Vehicle" do
      fill_in "Make", with: "Toyota"
      fill_in "Model", with: "Camry"
      fill_in "Year", with: "2020"
      fill_in "Mileage", with: "30000"
    end
  end

  test "can create other asset account" do
    assert_account_created("OtherAsset")
  end

  test "can create credit card account" do
    assert_account_created "CreditCard" do
      fill_in "Available credit", with: 1000
      fill_in "account[accountable_attributes][minimum_payment]", with: 25.51
      fill_in "APR", with: 15.25
      fill_in "Expiration date", with: 1.year.from_now.to_date
      fill_in "Annual fee", with: 100
    end
  end

  test "can create loan account" do
    assert_account_created "Loan" do
      fill_in "account[accountable_attributes][initial_balance]", with: 1000
      fill_in "Interest rate", with: 5.25
      select "Fixed", from: "Rate type"
      fill_in "Term (months)", with: 360
    end
  end

  test "can create other liability account" do
    assert_account_created("OtherLiability")
  end

  private

    def open_new_account_modal
      within "[data-controller='DS--tabs']" do
        click_button "All"
        click_link "New account"
      end
    end

    # The account page issues a Turbo morph refresh shortly after it loads
    # (`turbo_refreshes_with method: :morph` reacting to a family-stream
    # broadcast). Opening the menu while that refresh is in flight can detach the
    # node mid-click ("Node with given id does not belong to the document") or
    # wipe the just-opened edit form — neither of which Capybara auto-retries.
    # Retry until the edit form is present so the test is deterministic instead
    # of racing the broadcast (mirrors PropertyTest#open_account_edit_dialog).
    def open_account_edit_dialog
      3.times do
        # A prior (slow) attempt may have already opened the edit form.
        return if has_field?("Account name", wait: 0)

        begin
          within_testid("account-menu") do
            # Open the menu only when it's closed. DS::Menu's trigger toggles
            # (menu_controller#toggle), so blindly re-clicking an already-open
            # menu would close it and hide "Edit", turning a slow-but-successful
            # modal load into a fresh flake.
            unless has_selector?("[role='menu']", visible: true, wait: 0)
              find("button").click
            end
            click_on "Edit"
          end
        rescue Selenium::WebDriver::Error::WebDriverError => e
          raise unless e.message.match?(
            /does not belong to the document|stale element reference/i,
          )
          next
        end
        return if has_field?("Account name", wait: 2)
      end
      assert_field "Account name"
    end

    def assert_account_created(accountable_type, &block)
      click_link Accountable.from_type(accountable_type).singular_display_name
      click_link "Enter account balance" if accountable_type.in?(%w[Depository Investment Insurance Crypto Loan CreditCard])

      account_name = "[system test] #{accountable_type} Account"
      institution_name = "[system test] Institution"
      institution_domain = "example.com"
      notes = "Test notes for #{accountable_type}"

      fill_in "Account name*", with: account_name
      fill_in "account[balance]", with: 100.99
      find("summary", text: "Additional details").click
      fill_in "Institution name", with: institution_name
      fill_in "Institution domain", with: institution_domain
      fill_in "Notes", with: notes

      yield if block_given?

      click_button "Create Account"

      within_testid("account-sidebar-tabs") do
        click_on "All"
        find("details", text: Accountable.from_type(accountable_type).display_name).click
        assert_text account_name
      end

      visit accounts_url
      assert_text account_name

      created_account = Account.order(:created_at).last
      assert_equal institution_name, created_account[:institution_name]
      assert_equal institution_domain, created_account[:institution_domain]
      assert_equal notes, created_account[:notes]

      visit account_url(created_account)
      # Let the initial page (and any immediate Turbo morph) settle before
      # opening the edit dialog — same race as open_account_edit_dialog.
      assert_selector "h2", text: account_name

      updated_institution_name = "[system test] Updated Institution"
      updated_institution_domain = "updated.example.com"
      updated_notes = "Updated notes for #{accountable_type}"

      update_account_details(
        name: "Updated account name",
        institution_name: updated_institution_name,
        institution_domain: updated_institution_domain,
        notes: updated_notes
      )

      created_account.reload
      assert_equal updated_institution_name, created_account[:institution_name]
      assert_equal updated_institution_domain, created_account[:institution_domain]
      assert_equal updated_notes, created_account[:notes]
    end

    # Fill + submit the account edit dialog, retrying when a Turbo morph
    # detaches nodes mid-interaction (Chrome: "Node with given id does not
    # belong to the document"). Mirrors open_account_edit_dialog.
    def update_account_details(name:, institution_name:, institution_domain:, notes:)
      3.times do
        begin
          open_account_edit_dialog unless has_field?("Account name", wait: 0)

          fill_in "Account name", with: name
          unless has_field?("Institution name", wait: 0)
            find("summary", text: "Additional details").click
          end
          fill_in "Institution name", with: institution_name
          fill_in "Institution domain", with: institution_domain
          fill_in "Notes", with: notes
          click_button "Update Account"

          return if has_selector?("h2", text: name, wait: 2)
        rescue Selenium::WebDriver::Error::WebDriverError => e
          raise unless e.message.match?(
            /does not belong to the document|stale element reference/i,
          )
        end
      end

      assert_selector "h2", text: name
    end

    def humanized_accountable(accountable_type)
      Accountable.from_type(accountable_type).singular_display_name
    end
end
