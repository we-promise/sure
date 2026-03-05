require "test_helper"

class Transfer::CreatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @source_account = accounts(:depository)
    @destination_account = accounts(:investment)
    @date = Date.current
    @amount = 100
    # Ensure the Investment Contributions category exists for transfer tests
    @investment_category = ensure_investment_contributions_category(@family)
  end

  test "creates investment contribution when transferring from depository to investment" do
    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: @destination_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert_equal "confirmed", transfer.status

    # Verify outflow transaction is marked as investment_contribution
    outflow = transfer.outflow_transaction
    assert_equal "investment_contribution", outflow.kind
    assert outflow.transfer?, "investment_contribution should be recognized as a transfer"
    assert_equal @amount, outflow.entry.amount
    assert_equal @source_account.currency, outflow.entry.currency
    assert_equal "Transfer to #{@destination_account.name}", outflow.entry.name
    assert_equal @investment_category, outflow.category, "Should auto-assign Investment Contributions category"

    # Verify inflow transaction (always funds_movement)
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert inflow.transfer?, "funds_movement should be recognized as a transfer"
    assert_equal(@amount * -1, inflow.entry.amount)
    assert_equal @destination_account.currency, inflow.entry.currency
    assert_equal "Transfer from #{@source_account.name}", inflow.entry.name
  end

  test "creates basic transfer between depository accounts" do
    other_depository = @family.accounts.create!(name: "Savings", balance: 1000, currency: "USD", accountable: Depository.new)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: other_depository.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert_equal "confirmed", transfer.status
    assert transfer.regular_transfer?
    assert_equal "transfer", transfer.transfer_type

    # Verify outflow transaction (depository to depository = funds_movement)
    outflow = transfer.outflow_transaction
    assert_equal "funds_movement", outflow.kind
    assert_nil outflow.category, "Should NOT auto-assign category for regular transfers"

    # Verify inflow transaction
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
  end

  test "creates investment contribution when transferring from depository to crypto" do
    crypto_account = accounts(:crypto)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: crypto_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?

    # Verify outflow transaction is investment_contribution (not funds_movement)
    outflow = transfer.outflow_transaction
    assert_equal "investment_contribution", outflow.kind
    assert_equal "Transfer to #{crypto_account.name}", outflow.entry.name
    assert_equal @investment_category, outflow.category

    # Verify inflow transaction with currency handling
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal "Transfer from #{@source_account.name}", inflow.entry.name
    assert_equal crypto_account.currency, inflow.entry.currency
  end

  test "creates funds_movement for investment to investment transfer (rollover)" do
    # Rollover case: investment → investment should stay as funds_movement
    other_investment = @family.accounts.create!(name: "IRA", balance: 5000, currency: "USD", accountable: Investment.new)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @destination_account.id, # investment account
      destination_account_id: other_investment.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?

    # Verify outflow is funds_movement (NOT investment_contribution for rollovers)
    outflow = transfer.outflow_transaction
    assert_equal "funds_movement", outflow.kind
    assert_nil outflow.category, "Should NOT auto-assign category for investment→investment transfers"

    # Verify inflow
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
  end

  test "creates loan payment" do
    loan_account = accounts(:loan)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: loan_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert transfer.loan_payment?
    assert_equal "loan_payment", transfer.transfer_type

    # Verify outflow transaction is marked as loan payment
    outflow = transfer.outflow_transaction
    assert_equal "loan_payment", outflow.kind
    assert_equal "Payment to #{loan_account.name}", outflow.entry.name

    # Verify inflow transaction
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal "Payment from #{@source_account.name}", inflow.entry.name
  end

  test "creates credit card payment" do
    credit_card_account = accounts(:credit_card)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: @source_account.id,
      destination_account_id: credit_card_account.id,
      date: @date,
      amount: @amount
    )

    transfer = creator.create

    assert transfer.persisted?
    assert transfer.liability_payment?
    assert_equal "liability_payment", transfer.transfer_type

    # Verify outflow transaction is marked as payment for liability
    outflow = transfer.outflow_transaction
    assert_equal "cc_payment", outflow.kind
    assert_equal "Payment to #{credit_card_account.name}", outflow.entry.name

    # Verify inflow transaction
    inflow = transfer.inflow_transaction
    assert_equal "funds_movement", inflow.kind
    assert_equal "Payment from #{@source_account.name}", inflow.entry.name
  end

  test "raises error when source account ID is invalid" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: @family,
        source_account_id: 99999,
        destination_account_id: @destination_account.id,
        date: @date,
        amount: @amount
      )
    end
  end

  test "raises error when destination account ID is invalid" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: @family,
        source_account_id: @source_account.id,
        destination_account_id: 99999,
        date: @date,
        amount: @amount
      )
    end
  end

  test "raises error when source account belongs to different family" do
    other_family = families(:empty)

    assert_raises(ActiveRecord::RecordNotFound) do
      Transfer::Creator.new(
        family: other_family,
        source_account_id: @source_account.id,
        destination_account_id: @destination_account.id,
        date: @date,
        amount: @amount
      )
    end
  end

  test "creates transfer with custom exchange rate when provided" do
    # Create accounts with different currencies
    usd_account = @family.accounts.create!(name: "USD Account", balance: 1000, currency: "USD", accountable: Depository.new)
    eur_account = @family.accounts.create!(name: "EUR Account", balance: 1000, currency: "EUR", accountable: Depository.new)

    custom_rate = 0.92 # 1 USD = 0.92 EUR
    amount = 100

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: usd_account.id,
      destination_account_id: eur_account.id,
      date: @date,
      amount: amount,
      exchange_rate: custom_rate
    )

    transfer = creator.create

    assert transfer.persisted?

    # Verify outflow transaction is in source currency
    outflow = transfer.outflow_transaction
    assert_equal amount, outflow.entry.amount
    assert_equal "USD", outflow.entry.currency

    # Verify inflow transaction uses custom exchange rate
    inflow = transfer.inflow_transaction
    expected_eur_amount = (amount * custom_rate * -1).round(2)
    assert_in_delta expected_eur_amount, inflow.entry.amount, 0.01
    assert_equal "EUR", inflow.entry.currency
  end

  test "falls back to fetched exchange rate when custom rate not provided" do
    # Create accounts with different currencies
    usd_account = @family.accounts.create!(name: "USD Account", balance: 1000, currency: "USD", accountable: Depository.new)
    gbp_account = @family.accounts.create!(name: "GBP Account", balance: 1000, currency: "GBP", accountable: Depository.new)

    # Mock the exchange rate lookup
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "USD", to: "GBP", date: @date)
                .returns(OpenStruct.new(rate: 0.79))

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: usd_account.id,
      destination_account_id: gbp_account.id,
      date: @date,
      amount: 100
    )

    transfer = creator.create

    assert transfer.persisted?
    assert_equal "USD", transfer.outflow_transaction.entry.currency
    assert_equal "GBP", transfer.inflow_transaction.entry.currency
  end

  test "uses 1:1 fallback when no exchange rate available and none provided" do
    # Create accounts with different currencies
    usd_account = @family.accounts.create!(name: "USD Account", balance: 1000, currency: "USD", accountable: Depository.new)
    jpy_account = @family.accounts.create!(name: "JPY Account", balance: 100000, currency: "JPY", accountable: Depository.new)

    # Mock no exchange rate found
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "USD", to: "JPY", date: @date)
                .returns(nil)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: usd_account.id,
      destination_account_id: jpy_account.id,
      date: @date,
      amount: 100
    )

    transfer = creator.create

    assert transfer.persisted?

    # Should use 1:1 fallback
    outflow = transfer.outflow_transaction
    assert_equal 100, outflow.entry.amount

    inflow = transfer.inflow_transaction
    assert_equal(-100, inflow.entry.amount)
  end

  test "custom exchange rate with very small value is valid" do
    usd_account = @family.accounts.create!(name: "USD Account", balance: 1000, currency: "USD", accountable: Depository.new)
    eur_account = @family.accounts.create!(name: "EUR Account", balance: 1000, currency: "EUR", accountable: Depository.new)

    creator = Transfer::Creator.new(
      family: @family,
      source_account_id: usd_account.id,
      destination_account_id: eur_account.id,
      date: @date,
      amount: 100,
      exchange_rate: 0.000001
    )

    transfer = creator.create

    assert transfer.persisted?
    assert_in_delta(-0.0001, transfer.inflow_transaction.entry.amount, 0.0001)
  end
end
