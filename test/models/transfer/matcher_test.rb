require "test_helper"

class Transfer::MatcherTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @checking = accounts(:depository)
    @card = accounts(:credit_card)
    @loan = accounts(:loan)
    @investment = accounts(:investment)
  end

  test "matches an outflow with an existing opposite transaction" do
    outflow = create_transaction(account: @checking, amount: 250, date: Date.current).transaction
    inflow = create_transaction(account: @card, amount: -250, date: 2.days.ago.to_date).transaction

    transfer = Transfer::Matcher.new(outflow).match_with!(inflow)

    assert transfer.persisted?
    assert transfer.confirmed?
    assert_equal outflow, transfer.outflow_transaction
    assert_equal inflow, transfer.inflow_transaction
    assert_equal 250, transfer.amount
    assert_equal "cc_payment", outflow.reload.kind
    assert_equal "funds_movement", inflow.reload.kind
  end

  test "matches from the inflow side too" do
    outflow = create_transaction(account: @checking, amount: 80).transaction
    inflow = create_transaction(account: @card, amount: -80).transaction

    transfer = Transfer::Matcher.new(inflow).match_with!(outflow)

    assert_equal outflow, transfer.outflow_transaction
    assert_equal inflow, transfer.inflow_transaction
  end

  test "creates the missing counterpart in a target account" do
    outflow = create_transaction(account: @checking, amount: 289.60, date: 3.days.ago.to_date).transaction

    transfer = assert_difference [ "Transfer.count", "Entry.count" ], 1 do
      Transfer::Matcher.new(outflow).match_to_account!(@loan)
    end

    inflow_entry = transfer.inflow_transaction.entry
    assert_equal @loan, inflow_entry.account
    assert_equal(-289.60, inflow_entry.amount)
    assert_equal outflow.entry.date, inflow_entry.date
    assert_equal "Transfer to #{@loan.name}", inflow_entry.name
    assert inflow_entry.user_modified?
    assert_equal "loan_payment", outflow.reload.kind
  end

  test "sets the investment contributions category on an uncategorized outflow" do
    outflow = create_transaction(account: @checking, amount: 500).transaction

    Transfer::Matcher.new(outflow).match_to_account!(@investment)

    outflow.reload
    assert_equal "investment_contribution", outflow.kind
    assert_equal @family.investment_contributions_category, outflow.category
  end

  test "keeps a category the user already set" do
    category = categories(:food_and_drink)
    outflow = create_transaction(account: @checking, amount: 500, category: category).transaction

    Transfer::Matcher.new(outflow).match_to_account!(@investment)

    assert_equal category, outflow.reload.category
  end

  test "dry run validates without saving" do
    outflow = create_transaction(account: @checking, amount: 40).transaction

    transfer = assert_no_difference [ "Transfer.count", "Entry.count" ] do
      Transfer::Matcher.new(outflow).match_to_account!(@loan, dry_run: true)
    end

    assert transfer.new_record?
    assert_equal "standard", outflow.reload.kind
  end

  test "rejects a counterpart that is not a match candidate" do
    outflow = create_transaction(account: @checking, amount: 100).transaction
    wrong_amount = create_transaction(account: @card, amount: -99).transaction
    too_far = create_transaction(account: @card, amount: -100, date: 40.days.ago.to_date).transaction

    [ wrong_amount, too_far ].each do |counterpart|
      error = assert_raises(Transfer::Matcher::Error) { Transfer::Matcher.new(outflow).match_with!(counterpart) }
      assert_equal :not_a_candidate, error.code
    end

    assert_nil outflow.reload.transfer
  end

  test "refuses a transaction that is already in a transfer, including a pending auto-match" do
    outflow = create_transaction(account: @checking, amount: 100).transaction
    inflow = create_transaction(account: @card, amount: -100).transaction
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow, status: "pending")

    error = assert_raises(Transfer::Matcher::Error) { Transfer::Matcher.new(outflow).match_to_account!(@loan) }
    assert_equal :already_linked, error.code
  end

  test "refuses excluded and split transactions" do
    excluded = create_transaction(account: @checking, amount: 100, excluded: true).transaction
    error = assert_raises(Transfer::Matcher::Error) { Transfer::Matcher.new(excluded).match_to_account!(@loan) }
    assert_equal :excluded_transaction, error.code

    split = create_transaction(account: @checking, amount: 100).transaction
    Entry.any_instance.stubs(:split_parent?).returns(true)
    error = assert_raises(Transfer::Matcher::Error) { Transfer::Matcher.new(split).match_to_account!(@loan) }
    assert_equal :split_transaction, error.code
  end

  test "refuses the transaction's own account and another family's account" do
    outflow = create_transaction(account: @checking, amount: 100).transaction

    error = assert_raises(Transfer::Matcher::Error) { Transfer::Matcher.new(outflow).match_to_account!(@checking) }
    assert_equal :same_account, error.code

    other_family_account = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new)
    error = assert_raises(Transfer::Matcher::Error) { Transfer::Matcher.new(outflow).match_to_account!(other_family_account) }
    assert_equal :account_not_found, error.code
  end

  test "does not offer split children as candidates, or candidates for one" do
    parent = create_transaction(account: @card, amount: -100)
    children = parent.split!([ { name: "Part A", amount: -60 }, { name: "Part B", amount: -40 } ])
    outflow = create_transaction(account: @checking, amount: 60).transaction

    assert_empty Transfer::Matcher.new(outflow).candidates
    assert_empty Transfer::Matcher.new(children.first.entryable).candidates
  end

  test "lists candidates with the manual dialog's 30 day window" do
    outflow = create_transaction(account: @checking, amount: 75, date: Date.current).transaction
    near = create_transaction(account: @card, amount: -75, date: 20.days.ago.to_date).transaction
    create_transaction(account: @card, amount: -75, date: 45.days.ago.to_date)

    ids = Transfer::Matcher.new(outflow).candidates.map(&:inflow_transaction_id)

    assert_equal [ near.id ], ids
  end
end
