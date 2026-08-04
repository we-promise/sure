require "test_helper"

class Assistant::Function::AccountActionsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "creates a manual account and returns its discoverable id" do
    function = Assistant::Function::CreateAccount.new(@user)

    assert_difference "@family.accounts.count", 1 do
      result = function.call(
        "name" => "MCP Wallet",
        "account_type" => "Depository",
        "subtype" => "checking",
        "balance" => 125.5,
        "currency" => "USD",
        "opening_balance_date" => Date.current.iso8601
      )

      assert_equal true, result[:success]
      account = @family.accounts.find(result.dig(:account, :id))
      assert_equal @user, account.owner
      assert_equal "MCP Wallet", account.name
      assert_equal 125.5, account.balance
      assert_equal "Depository", account.accountable_type
    end
  end

  test "updates a writable manual account" do
    account = accounts(:depository)
    function = Assistant::Function::UpdateAccount.new(@user)

    result = function.call(
      "id" => account.id,
      "name" => "Main Wallet",
      "balance" => 777.25,
      "notes" => "Managed through MCP",
      "exclude_from_reports" => true
    )

    assert_equal true, result[:success]
    account.reload
    assert_equal "Main Wallet", account.name
    assert_equal 777.25, account.balance
    assert_equal "Managed through MCP", account.notes
    assert account.exclude_from_reports?
  end

  test "schedules a manual account for deletion" do
    account = accounts(:depository)
    function = Assistant::Function::DeleteAccount.new(@user)

    assert_enqueued_with(job: DestroyJob, args: [ account ]) do
      result = function.call("id" => account.id)
      assert_equal true, result[:success]
      assert_equal account.id, result[:deleted_account_id]
    end

    assert account.reload.pending_deletion?
  end

  test "does not delete linked accounts" do
    account = accounts(:connected)
    function = Assistant::Function::DeleteAccount.new(@user)

    assert_no_enqueued_jobs only: DestroyJob do
      result = function.call("id" => account.id)
      assert_equal false, result[:success]
      assert_equal "linked_account", result[:error]
    end

    refute account.reload.pending_deletion?
  end

  test "does not allow a provider link after deletion is scheduled" do
    account = @family.accounts.create!(
      owner: @user,
      name: "Pending deletion account",
      accountable: Depository.new,
      balance: 0,
      currency: "USD"
    )
    account.destroy_later
    link = AccountProvider.new(account: account, provider: plaid_accounts(:one))

    assert_not link.save
    assert_includes link.errors[:account], "is pending deletion and cannot be linked"
  end
end
