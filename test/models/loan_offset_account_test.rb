require "test_helper"

class LoanOffsetAccountTest < ActiveSupport::TestCase
  setup do
    @loan = accounts(:loan).loan
    @offset = @loan.account.family.accounts.create!(
      name: "Test offset", balance: 0, currency: "USD", accountable: Depository.new
    )
  end

  test "links only asset accounts in the same currency and family" do
    link = LoanOffsetAccount.new(loan: @loan, account: @offset)
    assert_predicate link, :valid?

    liability_link = LoanOffsetAccount.new(loan: @loan, account: accounts(:credit_card))
    assert_not liability_link.valid?
    assert_includes liability_link.errors[:account],
      "must be an asset account"
  end

  test "rejects the loan account and a different currency" do
    self_link = LoanOffsetAccount.new(loan: @loan, account: @loan.account)
    assert_not self_link.valid?
    assert_includes self_link.errors[:account], "cannot be the loan account"

    euro = @loan.account.family.accounts.create!(
      name: "Euro offset", balance: 100, currency: "EUR", accountable: Depository.new
    )
    different_currency = LoanOffsetAccount.new(loan: @loan, account: euro)
    assert_not different_currency.valid?
    assert_includes different_currency.errors[:account], "must use the same currency as the loan"
  end

  test "requires every loan viewer to see the offset account" do
    @loan.account.share_with!(users(:family_member), permission: "read_only")
    link = LoanOffsetAccount.new(loan: @loan, account: @offset)

    assert_not link.valid?
    assert_match "must be visible to every loan viewer", link.errors[:account].join

    @offset.share_with!(users(:family_member), permission: "read_only")
    assert_predicate link, :valid?
  end

  test "sharing changes invalidate an existing offset link" do
    link = @loan.loan_offset_accounts.create!(account: @offset)
    assert_difference -> { LoanOffsetAccount.count }, -1 do
      @loan.account.share_with!(users(:family_member), permission: "read_only")
    end

    assert_not LoanOffsetAccount.exists?(link.id)
  end

  test "revoking offset-account access invalidates an existing link" do
    @offset.share_with!(users(:family_member), permission: "read_only")
    @loan.account.share_with!(users(:family_member), permission: "read_only")
    link = @loan.loan_offset_accounts.create!(account: @offset)

    assert_difference -> { LoanOffsetAccount.count }, -1 do
      @offset.unshare_with!(users(:family_member))
    end

    assert_not LoanOffsetAccount.exists?(link.id)
  end

  test "granting offset-account access preserves an existing link" do
    link = @loan.loan_offset_accounts.create!(account: @offset)

    assert_no_difference -> { LoanOffsetAccount.count } do
      @offset.share_with!(users(:family_member), permission: "read_only")
    end

    assert LoanOffsetAccount.exists?(link.id)
  end

  test "rejects a stale link when a loan viewer loses offset-account access" do
    offset = @loan.account.family.accounts.create!(
      name: "Stale offset", balance: 12_500, currency: "USD", accountable: Depository.new
    )
    viewer = users(:family_member)
    @loan.update!(rate_type: "variable")
    offset.share_with!(viewer, permission: "full_control")
    @loan.account.share_with!(viewer, permission: "full_control")
    @loan.loan_offset_accounts.create!(account: offset)
    offset.unshare_with!(viewer)

    @loan.offset_account_ids = [ offset.id ]

    assert_not LoanOffsetAccount.new(loan: @loan, account: offset).valid?
    assert_not @loan.save
    assert_includes @loan.errors[:offset_account_ids].join, "must be visible to every loan viewer"
  end

  test "removing the last link returns the loan to no offset accounts" do
    @loan.loan_offset_accounts.create!(account: @offset)
    assert_equal [ @offset.id ], @loan.reload.offset_accounts.pluck(:id)

    @loan.loan_offset_accounts.delete_all
    assert_empty @loan.reload.offset_accounts
  end
end
