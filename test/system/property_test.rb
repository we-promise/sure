require "application_system_test_case"

class PropertiesEditTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    Family.any_instance.stubs(:get_link_token).returns("test-link-token")

    visit root_url
    open_new_account_modal
    create_new_property_account
  end

  test "can persist property subtype" do
    click_link "[system test] Property Account"
    assert_edit_dialog_field "account_accountable_attributes_subtype", with: "single_family_home"
  end

  private

    # The account page issues a Turbo morph refresh shortly after it loads
    # (`turbo_refreshes_with method: :morph` reacting to a family-stream
    # broadcast). If the edit modal is opened while that refresh is in flight,
    # the morph re-renders the page and wipes the just-loaded `#modal`
    # turbo-frame before the dialog is interactive — and can detach the menu
    # node mid-click ("Node with given id does not belong to the document"),
    # which Capybara does not auto-retry. Open via the account menu and retry
    # until the edit form shows the expected value. The value is checked inside
    # the retry: checking only that the field exists and asserting the value
    # afterwards lets a morph remove the modal in between, and the caller's
    # assertion then waits on a field that never comes back.
    def assert_edit_dialog_field(locator, with:)
      found = 3.times.any? do
        # A prior (slow) attempt may have already opened the edit form. Check
        # the field is enabled, not just present — the select briefly exists
        # but disabled while the form finishes hydrating, and has_field?'s
        # default matcher excludes disabled fields.
        next true if has_field?(locator, with: with, wait: 0)
        # An open form with another value is a real failure; reopening the
        # dialog would not change the value, so let the final assertion report it.
        next false if has_field?(locator, wait: 0)

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
        rescue Capybara::ElementNotFound
          # A morph can also close the menu without detaching its node.
          next false
        rescue Selenium::WebDriver::Error::WebDriverError => e
          raise unless e.message.match?(
            /does not belong to the document|stale element reference/i,
          )
          next false
        end
        has_field?(locator, with: with, wait: 2)
      end
      return pass if found

      assert_field locator, with: with
    end

    def open_new_account_modal
      within "[data-controller='DS--tabs']" do
        click_button "All"
        click_link "New account"
      end
    end

    def create_new_property_account
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
end
