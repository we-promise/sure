require "application_system_test_case"

class TransactionsFormExchangeRateTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account_usd = accounts(:depository) # USD account
    sign_in @user

    # Set up real exchange rates for testing
    @eur_usd_rate = ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.1
    )

    @gbp_usd_rate = ExchangeRate.create!(
      from_currency: "GBP",
      to_currency: "USD",
      date: Date.current,
      rate: 1.27
    )
  end

  test "changing amount currency to different currency shows exchange rate UI" do
    visit new_transaction_path

    # Select USD account (which is in USD)
    select_ds("Account", @account_usd)

    # Currency defaults to USD (same as account)
    # Change currency to EUR
    find("select[data-money-field-target='currency']").find("option[value='EUR']").select_option

    # Exchange rate UI should appear
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true
  end

  test "changing amount currency to same as account currency hides exchange rate UI" do
    visit new_transaction_path

    # Select USD account
    select_ds("Account", @account_usd)

    # Change to EUR first
    find("select[data-money-field-target='currency']").find("option[value='EUR']").select_option

    # Verify exchange rate UI is shown
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true

    # Change back to USD (same as account)
    find("select[data-money-field-target='currency']").find("option[value='USD']").select_option

    # Exchange rate UI should hide
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: false
  end

  test "exchange rate field is prefilled when rate is available" do
    visit new_transaction_path

    # Select USD account
    select_ds("Account", @account_usd)

    # Change to GBP (exchange rate is set up in fixtures)
    find("select[data-money-field-target='currency']").find("option[value='GBP']").select_option

    # Wait for exchange rate container to become visible
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true

    # Exchange rate field should be populated
    exchange_rate_field = find("[data-transaction-form-target='exchangeRateField']")
    assert_not_empty exchange_rate_field.value
    assert_equal "1.27", exchange_rate_field.value
  end

  test "exchange rate field is empty when rate not found" do
    visit new_transaction_path

    # Select USD account
    select_ds("Account", @account_usd)

    # Change to CHF (Swiss Franc - no rate set up in fixtures)
    find("select[data-money-field-target='currency']").find("option[value='CHF']").select_option

    # Wait for exchange rate container to become visible (manual rate entry mode)
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true

    # Exchange rate section should be visible but field should be empty (manual entry)
    exchange_rate_field = find("[data-transaction-form-target='exchangeRateField']")
    assert_empty exchange_rate_field.value
  end

  test "exchange rate is recalculated when currency changes" do
    visit new_transaction_path

    # Select USD account
    select_ds("Account", @account_usd)

    # Change to EUR
    find("select[data-money-field-target='currency']").find("option[value='EUR']").select_option

    # Wait for EUR rate to load
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true
    first_rate = find("[data-transaction-form-target='exchangeRateField']").value
    assert_equal "1.10", first_rate

    # Change to GBP
    find("select[data-money-field-target='currency']").find("option[value='GBP']").select_option

    # Wait for GBP rate to be updated
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true
    second_rate = find("[data-transaction-form-target='exchangeRateField']").value
    assert_equal "1.27", second_rate

    # Rates should be different
    assert_not_equal first_rate, second_rate
  end

  test "changing account also recalculates exchange rate for current currency" do
    # Create a second account in EUR
    eur_account = @family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    visit new_transaction_path

    # Start with USD account, then currency EUR
    select_ds("Account", @account_usd)

    find("select[data-money-field-target='currency']").find("option[value='EUR']").select_option

    # Exchange rate shown (both USD and EUR exist, they differ)
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true

    # Switch to EUR account
    select_ds("Account", eur_account)

    # Now account is EUR and currency is EUR (same)
    # Exchange rate UI should hide
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: false
  end
end
