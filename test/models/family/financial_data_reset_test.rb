require "test_helper"

class Family::FinancialDataResetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @other_family = families(:empty)
    @other_category = @other_family.categories.create!(
      name: "Keep Me",
      color: "#12B76A",
      lucide_icon: "tag"
    )
  end

  test "dry run reports target counts and deletes nothing" do
    result = Family::FinancialDataReset.new(user: @user).call

    assert result.dry_run
    assert_operator result.before_counts[:accounts], :>, 0
    assert_operator result.before_counts[:categories], :>, 0
    assert_equal result.before_counts, result.after_counts
    assert result.deleted_counts.values.all?(&:zero?)
    assert User.exists?(@user.id)
  end

  test "destructive reset requires explicit confirmation" do
    assert_raises Family::FinancialDataReset::ConfirmationRequiredError do
      Family::FinancialDataReset.new(user: @user, dry_run: false).call
    end
  end

  test "destructive reset clears financial data for one family and preserves users" do
    create_extra_target_data!

    result = Family::FinancialDataReset.new(
      user: @user,
      dry_run: false,
      confirmed: true
    ).call

    assert_not result.dry_run
    assert result.before_counts.values.any?(&:positive?)
    assert_equal 0, result.after_counts.values.sum
    assert result.deleted_counts.values.any?(&:positive?)
    assert User.exists?(@user.id)
    assert_equal @family.id, User.find(@user.id).family_id
    assert Category.exists?(@other_category.id)
  end

  test "destructive reset is idempotent" do
    first = Family::FinancialDataReset.new(user: @user, dry_run: false, confirmed: true).call
    second = Family::FinancialDataReset.new(user: @user, dry_run: false, confirmed: true).call

    assert_equal 0, first.after_counts.values.sum
    assert_equal 0, second.before_counts.values.sum
    assert_equal 0, second.after_counts.values.sum
  end

  private

    def create_extra_target_data!
      account = @family.accounts.create!(
        name: "Reset Test Checking",
        balance: 100,
        currency: "USD",
        accountable: Depository.new
      )
      category = @family.categories.create!(
        name: "Reset Test Category",
        color: "#407706",
        lucide_icon: "shapes"
      )
      tag = @family.tags.create!(name: "Reset Test Tag", color: "#12B76A")
      merchant = @family.merchants.create!(name: "Reset Test Merchant", color: "#12B76A")
      transaction = Transaction.create!(category: category, merchant: merchant)
      transaction.taggings.create!(tag: tag)
      account.entries.create!(
        entryable: transaction,
        name: "Reset test transaction",
        date: Date.current,
        amount: 12,
        currency: "USD"
      )
      account.balances.create!(date: Date.current, balance: 100, currency: "USD")
      account.holdings.create!(
        security: securities(:aapl),
        date: Date.current,
        qty: 1,
        price: 100,
        amount: 100,
        currency: "USD"
      )
      @family.recurring_transactions.create!(
        account: account,
        merchant: merchant,
        amount: 12,
        currency: "USD",
        expected_day_of_month: 1,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: 1.month.from_now.to_date,
        status: "active"
      )
      @family.rules.build(name: "Reset Test Rule", resource_type: "transaction").tap do |rule|
        rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "Reset")
        rule.actions.build(action_type: "set_transaction_category", value: category.id)
        rule.save!
      end
      @family.imports.create!(type: "TransactionImport", status: "pending")
    end
end
