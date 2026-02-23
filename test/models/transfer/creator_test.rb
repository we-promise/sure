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
end
