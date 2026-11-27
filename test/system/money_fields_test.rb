require "application_system_test_case"

# Every amount input is the shared money field: a comma decimal or a simple
# expression is read the same way as on a new transaction, and the server gets
# a plain number.
class MoneyFieldsTest < ApplicationSystemTestCase
  include EntriesTestHelper
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
  end

  test "a transfer reads a comma decimal expression and comma fees" do
    visit transactions_url
    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:credit_card))

    fill_in "transfer[amount]", with: "12,50+4,30"
    find("summary", text: /bank charges/i).click
    fill_in "transfer[source_fee_amount]", with: "1,25"
    fill_in "Date", with: Date.current

    click_button "Create transfer"

    within "#entry-group-#{Date.current}" do
      assert_text "Payment to"
    end
    transfer = Transfer.joins(outflow_transaction: :entry).where(entries: { account_id: accounts(:depository).id }).order(created_at: :desc).first
    assert_equal 16.80.to_d, transfer.outflow_transaction.entry.amount
    assert_equal 1.25.to_d, transfer.derived_source_fee_amount
  end

  test "a transfer's amount shows the currency of the account it leaves" do
    eur_account = @user.family.accounts.create!(name: "EUR Savings", balance: 1000, currency: "EUR", accountable: Depository.new)

    visit new_transfer_url

    amount_field = find_field("transfer[amount]").ancestor("[data-controller='money-field']")
    assert_selector "[data-money-field-target='symbol']", text: "$"

    select_ds("From", eur_account)

    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "€" }
  end

  test "text typed while a currency switch loads is read for the new currency" do
    jpy_account = @user.family.accounts.create!(name: "JPY Savings", balance: 100_000, currency: "JPY", accountable: Depository.new)

    visit new_transfer_url
    amount_field = find_field("transfer[amount]").ancestor("[data-controller='money-field']")
    select_ds("From", jpy_account)
    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "¥" }

    # Hold the next currency lookup until the test releases it.
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.heldCurrencyLookups = [];
      window.fetch = (url, ...rest) => {
        if (!String(url).includes("/currencies/")) return originalFetch(url, ...rest);
        return new Promise((resolve) => window.heldCurrencyLookups.push(() => resolve(originalFetch(url, ...rest))));
      };
    JS

    select_ds("From", accounts(:depository))
    fill_in "transfer[amount]", with: "1.234"
    # The amount and the source fee both follow the source account.
    assert_operator page.evaluate_script("window.heldCurrencyLookups.length"), :>=, 1

    submitted = 'new FormData(document.querySelector("input[name=\'transfer[amount]\']").form).get("transfer[amount]")'
    # Not JPY's grouping reading (1234): the text was typed for USD.
    assert_equal "1.234", page.evaluate_script(submitted)

    page.execute_script("window.heldCurrencyLookups.forEach((release) => release())")
    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "$" }
    assert_equal "1.23", find_field("transfer[amount]").value
    assert_equal "1.23", page.evaluate_script(submitted)
  end

  test "a transfer's exchange rate reads a comma decimal" do
    eur_account = @user.family.accounts.create!(name: "EUR Savings", balance: 1000, currency: "EUR", accountable: Depository.new)

    visit new_transfer_url
    select_ds("From", accounts(:depository))
    select_ds("To", eur_account)
    fill_in "transfer[amount]", with: "100"

    rate_field = find_field("transfer[exchange_rate]", visible: true)
    rate_field.fill_in(with: "1,1")

    assert_selector "[data-transfer-form-target='convertDestinationDisplay']", text: "110.00 EUR"
    submitted = 'new FormData(document.querySelector("input[name=\'transfer[exchange_rate]\']").form).get("transfer[exchange_rate]")'
    assert_equal "1.1", page.evaluate_script(submitted)
  end

  test "a calculated rate survives a date without a market rate" do
    eur_account = @user.family.accounts.create!(name: "EUR Savings", balance: 1000, currency: "EUR", accountable: Depository.new)

    visit new_transfer_url
    select_ds("From", accounts(:depository))
    select_ds("To", eur_account)
    fill_in "transfer[amount]", with: "100"
    find("button[data-id='calculateRate']").click
    find("[data-transfer-form-target='destinationAmount']").fill_in(with: "92")
    assert_selector "[data-transfer-form-target='calculateRateDisplay']", text: "0.92"

    # A placeholder the lookup for the new date must replace, so the check
    # below only passes once that lookup has landed (blanked without the fix).
    rate = 'document.querySelector("[data-transfer-form-target=\'exchangeRateField\']")'
    page.execute_script("#{rate}.value = '7'")
    fill_in "Date", with: 3.days.ago.to_date

    page.document.synchronize do
      raise Capybara::ExpectationNotMet unless page.evaluate_script("#{rate}.value").start_with?("0.92")
    end
    assert_selector "[data-transfer-form-target='calculateRateDisplay']", text: "0.92"
  end

  test "text typed between two pending currency switches keeps the new reading" do
    jpy_account = @user.family.accounts.create!(name: "JPY Savings", balance: 100_000, currency: "JPY", accountable: Depository.new)
    eur_account = @user.family.accounts.create!(name: "EUR Savings", balance: 1_000, currency: "EUR", accountable: Depository.new)

    visit new_transfer_url
    amount_field = find_field("transfer[amount]").ancestor("[data-controller='money-field']")
    select_ds("From", jpy_account)
    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "¥" }

    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.heldCurrencyLookups = [];
      window.fetch = (url, ...rest) => {
        if (!String(url).includes("/currencies/")) return originalFetch(url, ...rest);
        return new Promise((resolve) => window.heldCurrencyLookups.push(() => resolve(originalFetch(url, ...rest))));
      };
    JS

    select_ds("From", eur_account)
    fill_in "transfer[amount]", with: "1.234"
    # A second switch before the first lookup lands.
    select_ds("From", accounts(:depository))

    page.execute_script("window.heldCurrencyLookups.forEach((release) => release())")
    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "$" }
    # Read as USD's 1.234, not JPY's grouping (1234).
    assert_equal "1.23", find_field("transfer[amount]").value
  end

  test "a paste made while a currency switch loads is read with the new separator" do
    eur_account = @user.family.accounts.create!(name: "EUR Savings", balance: 1_000, currency: "EUR", accountable: Depository.new)

    visit new_transfer_url
    amount_field = find_field("transfer[amount]").ancestor("[data-controller='money-field']")
    select_ds("From", eur_account)
    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "€" }

    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.heldCurrencyLookups = [];
      window.fetch = (url, ...rest) => {
        if (!String(url).includes("/currencies/")) return originalFetch(url, ...rest);
        return new Promise((resolve) => window.heldCurrencyLookups.push(() => resolve(originalFetch(url, ...rest))));
      };
    JS

    select_ds("From", accounts(:depository))
    page.execute_script(<<~JS, find_field("transfer[amount]"))
      const [input] = arguments
      const data = new DataTransfer()
      data.setData("text/plain", "1,234")
      input.focus()
      input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }))
    JS

    # Its reading depends on the currency, so the form waits for the lookup.
    validity = 'document.querySelector("input[name=\'transfer[amount]\']").validity.valid'
    assert_equal false, page.evaluate_script(validity)

    page.execute_script("window.heldCurrencyLookups.forEach((release) => release())")
    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "$" }
    # A USD statement's "1,234" is a thousands amount, not 1.234.
    assert_equal "1234.00", find_field("transfer[amount]").value
    assert_equal true, page.evaluate_script(validity)
  end

  test "a paste kept for a currency lookup that fails stays invalid until edited" do
    eur_account = @user.family.accounts.create!(name: "EUR Savings", balance: 1_000, currency: "EUR", accountable: Depository.new)

    visit new_transfer_url
    amount_field = find_field("transfer[amount]").ancestor("[data-controller='money-field']")
    select_ds("From", eur_account)
    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "€" }

    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.heldCurrencyLookups = [];
      window.fetch = (url, ...rest) => {
        if (!String(url).includes("/currencies/")) return originalFetch(url, ...rest);
        return new Promise((_resolve, reject) => window.heldCurrencyLookups.push(() => {
          reject(new TypeError("offline"));
          // After the rejection's handlers have run.
          setTimeout(() => { window.lookupsFailed = true; }, 0);
        }));
      };
    JS

    select_ds("From", accounts(:depository))
    page.execute_script(<<~JS, find_field("transfer[amount]"))
      const [input] = arguments
      const data = new DataTransfer()
      data.setData("text/plain", "1,234")
      input.focus()
      input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }))
    JS

    validity = 'document.querySelector("input[name=\'transfer[amount]\']").validity.valid'
    page.execute_script("window.heldCurrencyLookups.forEach((fail) => fail())")
    Timeout.timeout(Capybara.default_max_wait_time) { sleep 0.05 until page.evaluate_script("window.lookupsFailed") }
    # The lookup failed, so "1,234" still has no reading.
    assert_equal false, page.evaluate_script(validity)

    fill_in "transfer[amount]", with: "1234"
    assert_equal true, page.evaluate_script(validity)
  end

  test "split rows add up typed comma amounts" do
    entry = create_transaction(amount: 100, name: "Split me", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      find("[data-split-transaction-target='amountInput']").fill_in(with: "-60,50")
      click_on I18n.t("splits.new.add_row")
      rows = all("[data-split-transaction-target='row']", count: 2)
      within(rows.last) do
        find("[data-split-transaction-target='nameInput']").fill_in(with: "Rest")
        find("[data-split-transaction-target='amountInput']").fill_in(with: "-39,50")
      end

      assert_selector "[data-split-transaction-target='remaining']", exact_text: "0.00"
    end
  end

  test "split rows are summed as they are submitted, rounded to the row" do
    entry = create_transaction(amount: 100, name: "Split three ways", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      find("[data-split-transaction-target='amountInput']").fill_in(with: "-100/3")
      2.times { click_on I18n.t("splits.new.add_row") }
      rows = all("[data-split-transaction-target='row']", count: 3)
      rows.drop(1).each_with_index do |row, index|
        within(row) do
          find("[data-split-transaction-target='nameInput']").fill_in(with: "Part #{index + 2}")
          find("[data-split-transaction-target='amountInput']").fill_in(with: "-100/3")
        end
      end

      # Each row submits -33.33, which leaves 0.01 that Entry#split! rejects.
      assert_selector "[data-split-transaction-target='remaining']", exact_text: "-0.01"
      assert_selector "[data-split-transaction-target='submitButton']:disabled"
    end
  end

  test "split rows balance a fractional total in a whole-number currency" do
    entry = create_transaction(amount: 80.4, currency: "JPY", name: "Imported", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      find("[data-split-transaction-target='amountInput']").fill_in(with: "-40")
      click_on I18n.t("splits.new.add_row")
      rows = all("[data-split-transaction-target='row']", count: 2)
      within(rows.last) do
        find("[data-split-transaction-target='nameInput']").fill_in(with: "Rest")
        find("[data-split-transaction-target='amountInput']").fill_in(with: "-40")
      end

      # 0.4 short: Entry#split! would reject it, so it must not read as balanced.
      assert_selector "[data-split-transaction-target='remaining']", exact_text: "-0.4"
      assert_selector "[data-split-transaction-target='submitButton']:disabled"

      within(rows.last) do
        find("[data-split-transaction-target='amountInput']").fill_in(with: "-40,4")
      end

      assert_selector "[data-split-transaction-target='remaining']", exact_text: "0.0"
      assert_selector "[data-split-transaction-target='submitButton']:not(:disabled)"
    end
  end

  test "a rule condition switched to amount gets the money field" do
    visit new_rule_url(resource_type: "transaction")

    within "dialog" do
      click_on "Add condition"
      condition = find("[data-rules-target='conditionsList'] li[data-controller='rule--conditions']", match: :first)
      within(condition) do
        find("select[name$='[condition_type]']").find("option[value='transaction_amount']").select_option

        assert_selector "[data-controller='money-field'] input[name$='[value]']"
        find("input[name$='[value]']").fill_in(with: "12,50")
        assert_equal "", find("input[name$='[value]']")[:validationMessage].to_s
      end
    end
  end

  test "a budget allocation saves a typed comma expression when the field is left" do
    budget = budgets(:one)
    category = Category.create!(name: "Money field dining", family: @user.family, color: "#4da568", lucide_icon: "utensils")
    budget_category = BudgetCategory.create!(budget: budget, category: category, budgeted_spending: 50, currency: "USD")

    visit budget_budget_categories_path(budget)

    field = find_field(id: dom_id(budget_category, :budgeted_spending))
    field.fill_in(with: "60+15,5")
    field.send_keys(:tab)

    wait_until { budget_category.reload.budgeted_spending == 75.5.to_d }
    assert_equal 75.5.to_d, budget_category.budgeted_spending
  end
end
