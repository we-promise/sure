require "test_helper"

class Loan::FinancedAccountTest < ActiveSupport::TestCase
  setup do
    @loan_account = accounts(:loan)
    @loan = @loan_account.loan
    @property = accounts(:property)
  end

  test "a loan can name the property it finances" do
    @loan.update!(financed_account: @property)

    assert_equal @property, @loan.reload.financed_account
    assert_equal [ @loan_account ], @property.financing_loan_accounts.to_a
  end

  test "only a property or vehicle can be financed" do
    @loan.financed_account = accounts(:depository)

    assert_not @loan.valid?
    assert @loan.errors.added?(:financed_account, :invalid)

    @loan.financed_account = accounts(:vehicle)
    assert @loan.valid?
  end

  test "an account from another family cannot be linked" do
    other = families(:empty).accounts.create!(name: "Elsewhere", balance: 1, currency: "USD", accountable: Property.new)

    @loan_account.assign_attributes(accountable_attributes: { id: @loan.id, financed_account_id: other.id })

    assert_not @loan_account.save
    assert_equal 1, @loan_account.errors.full_messages.size, @loan_account.errors.full_messages.inspect
    assert_nil @loan.reload.financed_account_id
  end

  test "a loan saved on its own cannot be linked to another family's asset" do
    other = families(:empty).accounts.create!(name: "Elsewhere", balance: 1, currency: "USD", accountable: Property.new)

    @loan.financed_account = other

    assert_not @loan.save
    assert @loan.errors.added?(:financed_account, :invalid)
    assert_nil @loan.reload.financed_account_id
  end

  test "a new loan can be created already linked" do
    account = @property.family.accounts.create!(
      name: "Land loan", balance: 1000, currency: "USD",
      accountable_type: "Loan", accountable_attributes: { financed_account_id: @property.id }
    )

    assert_equal @property, account.loan.financed_account
  end

  test "deleting the financed account clears the link" do
    @loan.update!(financed_account: @property)

    @property.destroy!

    assert_nil @loan.reload.financed_account_id
  end

  test "deleting the loan leaves the asset with no financing loans" do
    @loan.update!(financed_account: @property)

    @loan_account.destroy!

    assert_empty @property.reload.financing_loan_accounts
  end
end
