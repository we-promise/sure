require "test_helper"

class Assistant::Function::SetOpeningBalanceTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::SetOpeningBalance.new(@user)
    @account = families(:dylan_family).accounts.create!(
      name: "Manual savings", balance: 0, currency: "USD", accountable: Depository.new, owner: @user
    )
    @account.set_opening_anchor_balance(balance: 500, date: 30.days.ago.to_date)
    create_transaction(account: @account, amount: -10_000, date: 20.days.ago.to_date)
  end

  test "moves the opening balance and date" do
    result = @function.call("account_id" => @account.id, "balance" => 0, "date" => 25.days.ago.to_date.iso8601)

    assert_equal true, result[:success]
    assert_equal true, result[:changed]
    assert_equal({ date: 30.days.ago.to_date, balance: "500.0" }, result[:before])
    assert_equal 25.days.ago.to_date, result[:after][:date]

    anchor = @account.valuations.opening_anchor.first.entry
    assert_equal 0, anchor.amount
    assert_equal 25.days.ago.to_date, anchor.date
  end

  test "keeps the current date when none is given" do
    @function.call("account_id" => @account.id, "balance" => 750)

    anchor = @account.valuations.opening_anchor.first.entry
    assert_equal 750, anchor.amount
    assert_equal 30.days.ago.to_date, anchor.date
  end

  test "reports that the current balance moves when nothing later fixes it" do
    result = @function.call("account_id" => @account.id, "balance" => 0, "dry_run" => true)

    assert_equal true, result[:current_balance][:changes]
    assert_equal "-500.0", result[:current_balance][:by]
  end

  test "reports that a later balance update fixes the current balance" do
    Account::ReconciliationManager.new(@account).reconcile_balance(balance: 9_000, date: 5.days.ago.to_date)

    result = @function.call("account_id" => @account.id, "balance" => 0, "dry_run" => true)

    assert_equal false, result[:current_balance][:changes]
    assert_match 5.days.ago.to_date.to_s, result[:current_balance][:reason]
  end

  test "dry run changes nothing" do
    result = assert_no_difference "Entry.count" do
      @function.call("account_id" => @account.id, "balance" => 0, "date" => 25.days.ago.to_date.iso8601, "dry_run" => true)
    end

    assert_equal true, result[:dry_run]
    assert_equal 500, @account.valuations.opening_anchor.first.entry.amount
  end

  test "creates an opening balance when the account has none" do
    account = families(:dylan_family).accounts.create!(
      name: "No anchor", balance: 0, currency: "USD", accountable: Depository.new, owner: @user
    )

    result = @function.call("account_id" => account.id, "balance" => 0, "date" => 10.days.ago.to_date.iso8601)

    assert_equal true, result[:success]
    assert_nil result[:before]
    assert_equal 0, account.valuations.opening_anchor.first.entry.amount
  end

  test "rejects a date on or after the oldest entry, naming that date" do
    result = @function.call("account_id" => @account.id, "balance" => 0, "date" => 20.days.ago.to_date.iso8601)

    assert_equal false, result[:success]
    assert_equal "invalid_date", result[:error]
    assert_equal 20.days.ago.to_date, result[:oldest_entry_date]
    assert_equal 500, @account.valuations.opening_anchor.first.entry.amount
  end

  test "validates balance and date" do
    assert_equal "invalid_balance", @function.call("account_id" => @account.id, "balance" => "lots")[:error]
    assert_equal "invalid_balance", @function.call("account_id" => @account.id, "balance" => true)[:error]
    assert_equal "invalid_date", @function.call("account_id" => @account.id, "balance" => 0, "date" => "28/09/2026")[:error]
  end

  test "refuses accounts synced from a provider" do
    result = @function.call("account_id" => accounts(:connected).id, "balance" => 0)

    assert_equal "linked_account", result[:error]
  end

  test "refuses accounts the user can only read, and other families' accounts" do
    # family_member has a read-only share of the credit card
    result = Assistant::Function::SetOpeningBalance.new(users(:family_member)).call("account_id" => accounts(:credit_card).id, "balance" => 0)
    assert_equal "not_found", result[:error]

    result = Assistant::Function::SetOpeningBalance.new(users(:josh)).call("account_id" => @account.id, "balance" => 0)
    assert_equal "not_found", result[:error]
  end
end
