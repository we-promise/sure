require "test_helper"

class ValuableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:investment).family.accounts.create!(name: "Physical gold", currency: "USD", balance: 0, accountable: Valuable.new)
  end

  test "is a non cash asset independent of brokerage investments" do
    assert_equal "asset", @account.classification
    assert_equal :non_cash, @account.balance_type
    assert_not @account.supports_trades?
    assert_not @account.supports_statements?
    assert_equal "transfer", @account.default_pledge_kind
    assert accounts(:investment).supports_trades?
    assert accounts(:investment).supports_statements?
    assert Valuable.new.valid?
  end

  test "currency changes are allowed before purchases and refused after" do
    @account.update!(currency: "INR")
    lot = create_lot
    assert_equal "INR", lot.currency
    assert_not @account.update(currency: "USD")
    assert_equal "INR", @account.reload.currency
    assert_not lot.update(currency: "USD")
  end

  test "deleting the account destroys its lots and receipts" do
    lot = create_lot
    lot.invoice.attach(io: StringIO.new("receipt"), filename: "receipt.pdf", content_type: "application/pdf")
    assert_difference "ValuableItem.count", -1 do
      assert_difference "Valuable.count", -1 do
        @account.destroy!
      end
    end
    assert_not ActiveStorage::Attachment.exists?(record_type: "ValuableItem", record_id: lot.id)
  end

  test "lot changes enqueue valuation only when committed" do
    assert_enqueued_with(job: RefreshValuableValuationJob, args: [ @account.id ]) { create_lot }
    assert_no_enqueued_jobs(only: RefreshValuableValuationJob) do
      ValuableItem.transaction do
        create_lot
        raise ActiveRecord::Rollback
      end
    end
  end

  test "account statements cannot be assigned or matched to precious metals" do
    statement = AccountStatement.new(account: @account, family: @account.family)
    statement.valid?
    assert statement.errors[:account].any?
    match = AccountStatement::AccountMatcher.best_match(family: @account.family, account_name_hint: @account.name)
    assert_nil match
  end

  private
    def create_lot
      @account.valuable.lots.create!(description: "Bar", acquired_on: Date.current, weight: 1, weight_unit: "troy_ounce", karat: 24, cost_amount: 100, manual_value: 120)
    end
end
