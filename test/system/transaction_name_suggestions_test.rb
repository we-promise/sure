require "application_system_test_case"

class TransactionNameSuggestionsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.family.update!(auto_sync_on_login: false, auto_generate_transaction_names: true)
    sign_in @user
  end

  test "recent and searched names share one keyboard-accessible picker with category autofill" do
    open_new_transaction
    find("#entry_name").click
    assert_selector ".hw-combobox [role='option']", text: "Starbucks"
    assert_selector "input[role='combobox']", count: 1

    search_starbucks
    assert_selector ".hw-combobox [role='option']", text: "Starbucks"
    assert_selector ".hw-combobox [role='option']", count: 1
    find("#entry_name").send_keys(:arrow_down, :enter)
    assert_field "entry_name", with: "Starbucks"
    assert_category categories(:food_and_drink)

    fill_in "entry_name", with: "My custom purchase"
    find("input[name='entry[amount]']").set("12.34")
    click_button "Add transaction"
    assert_created_transaction "My custom purchase"
    entry = accounts(:depository).entries.find_by!(name: "My custom purchase")
    assert_equal "My custom purchase", entry.name
    assert_equal categories(:food_and_drink), entry.entryable.category
  end

  test "blank names keep the live category and merchant preview and save the generated name" do
    open_new_transaction
    select_starbucks
    fill_in "entry_name", with: ""
    choose_category categories(:food_and_drink)
    assert_selector "#entry_name[placeholder='Food & Drink']"
    assert_field "entry_name", with: ""
    assert_no_selector "#entry_name[required]"

    find("summary", text: /details/i).click
    find("[data-merchant-select-target='button']").click
    find("[data-merchant-select-target='option'][data-merchant-id='#{merchants(:amazon).id}']").click
    assert_selector "#entry_name[placeholder='Food & Drink - Amazon']"
    find("input[name='entry[amount]']").set("12.34")
    click_button "Add transaction"
    assert_created_transaction "Food & Drink - Amazon"
    entry = accounts(:depository).entries.find_by!(name: "Food & Drink - Amazon")
    assert_equal categories(:food_and_drink), entry.entryable.category
    assert_equal merchants(:amazon), entry.entryable.merchant
  end

  test "manual keyboard category selection and clearing survive subsequent name suggestions" do
    visit new_transaction_url(account_id: accounts(:depository).id)
    find("[data-category-select-target='button']").click
    fill_in "Search categories", with: "Income"
    find_field("Search categories").send_keys(:enter)
    select_starbucks
    assert_category categories(:income)

    choose_category nil
    select_starbucks
    assert_category nil
  end

  test "a prefilled category is not overwritten and names remain required when auto naming is off" do
    @user.family.update!(auto_generate_transaction_names: false)
    transactions(:one).update!(category: categories(:income))
    visit new_transaction_url(duplicate_entry_id: transactions(:one).entry.id)
    assert_selector "#entry_name[required]"
    assert_category categories(:income)
    select_starbucks
    assert_category categories(:income)
  end

  test "mobile picker selects a name and category without a second suggestions menu" do
    page.current_window.resize_to(390, 844)
    visit new_transaction_url(account_id: accounts(:depository).id)
    find("#entry_name").click

    within "dialog.hw-combobox__dialog" do
      find("input[role='combobox']").set("Starb")
      find("[role='option']", text: "Starbucks").click
    end

    assert_field "entry_name", with: "Starbucks"
    assert_category categories(:food_and_drink)
  end

  test "mobile free-text description survives dismissing the picker before suggestions return" do
    page.current_window.resize_to(390, 844)
    open_new_transaction
    hold_name_suggestions
    find("#entry_name").click

    within "dialog.hw-combobox__dialog" do
      find("input[role='combobox']").set("Saturday market run")
    end

    # The suggestions request has started and is held, so its response is
    # guaranteed not to have arrived before the picker is dismissed.
    assert_selector "html[data-name-search-pending]"

    within "dialog.hw-combobox__dialog" do
      # Dismiss the picker right away, without waiting for the suggestions
      # round-trip and without picking an option, as on a phone. The typed
      # description must stay in the field and save with the transaction.
      find("input[role='combobox']").send_keys(:escape)
    end

    assert_field "entry_name", with: "Saturday market run"
    release_name_suggestions

    find("input[name='entry[amount]']").set("12.34")
    click_button "Add transaction"
    assert_created_transaction "Saturday market run"
    entry = accounts(:depository).entries.find_by!(name: "Saturday market run")
    assert_equal "Saturday market run", entry.name
  end

  private
    def open_new_transaction
      # Open the modal from its real parent page so submission returns to the
      # account activity, rather than refreshing the standalone /new dialog.
      visit account_url(accounts(:depository), tab: "activity")
      within "[data-testid='activity-menu']" do
        click_on "New"
        click_on "New transaction"
      end
      assert_selector "turbo-frame#modal dialog[open] #entry_name"
    end

    def assert_created_transaction(name)
      # The toast is short-lived and can disappear during a Turbo refresh.
      # Wait for the durable result instead, retaining browser-level coverage.
      assert_no_selector "turbo-frame#modal dialog[open]"
      within "##{dom_id(accounts(:depository), :entries)}" do
        assert_text name
      end
    end

    def select_starbucks
      search_starbucks
      assert_selector ".hw-combobox [role='option']", count: 1
      assert_selector ".hw-combobox [role='option']", text: "Starbucks"
      find("#entry_name").send_keys(:arrow_down, :enter)
      assert_field "entry_name", with: "Starbucks"
    end

    def search_starbucks
      # Record the search request, then wait for its matching Turbo Stream
      # sentinel. Recent options can have identical text and counts.
      page.execute_script(<<~JS)
        delete document.documentElement.dataset.nameSearchCallback;
        if (!window.nameSearchFetchRecorded) {
          window.nameSearchFetchRecorded = true;
          const originalFetch = window.fetch;
          window.fetch = (url, init) => {
            const requestUrl = new URL(url, window.location.href);
            if (requestUrl.pathname === "/transactions/name_suggestions" && requestUrl.searchParams.get("q") === "Starb") {
              document.documentElement.dataset.nameSearchCallback = requestUrl.searchParams.get("callback_id");
            }
            return originalFetch(url, init);
          };
        }
      JS
      fill_in "entry_name", with: "Starb"
      assert_selector "html[data-name-search-callback]"
      callback_id = find("html")["data-name-search-callback"]
      assert_selector "[data-hw-combobox-target='endOfOptionsStream'][data-callback-id='#{callback_id}']", visible: :all
    end

    def hold_name_suggestions
      # Hold name-suggestion responses so the test controls exactly when they
      # arrive: the wrapper records that a request started
      # (html[data-name-search-pending]) and only performs the real fetch once
      # released. Same interception point as the fetch-recording hook in
      # search_starbucks.
      page.execute_script(<<~JS)
        delete document.documentElement.dataset.nameSearchPending;
        window.__heldNameSearches = [];
        if (!window.nameSearchHoldInstalled) {
          window.nameSearchHoldInstalled = true;
          const originalFetch = window.fetch;
          window.fetch = (url, init) => {
            const requestUrl = new URL(url, window.location.href);
            if (requestUrl.pathname === "/transactions/name_suggestions") {
              document.documentElement.dataset.nameSearchPending = "true";
              return new Promise((resolve) => {
                window.__heldNameSearches.push(() => resolve(originalFetch(url, init)));
              });
            }
            return originalFetch(url, init);
          };
        }
      JS
    end

    def release_name_suggestions
      page.execute_script(<<~JS)
        window.__heldNameSearches.splice(0).forEach((release) => release());
        delete document.documentElement.dataset.nameSearchPending;
      JS
    end

    def choose_category(category)
      find("[data-category-select-target='button']").click
      find("[data-category-select-target='option'][data-category-id='#{category&.id}']").click
    end

    def assert_category(category)
      assert_selector "[data-category-select-target='hiddenInput'][value='#{category&.id}']", visible: :all
    end
end
