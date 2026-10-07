require "test_helper"

class CategoriesHelperTest < ActionView::TestCase
  include CategoriesHelper

  setup do
    @family = families(:dylan_family)
    @category = @family.categories.create!(name: "Groceries")
  end

  test "returns the real category when present, even on a transfer leg" do
    transaction = Transaction.new(kind: "funds_movement", category: @category)

    assert_equal @category, display_category_for(transaction)
  end

  test "uncategorized regular transaction reads Uncategorized" do
    assert_equal Category.uncategorized.name, display_category_for(Transaction.new(kind: "standard")).name
  end

  test "categoryless funds_movement leg shows Transfer badge" do
    assert_equal transfer_category.name, display_category_for(transfer_leg("funds_movement", payment: false)).name
  end

  test "categoryless cc_payment leg shows Payment badge" do
    assert_equal payment_category.name, display_category_for(transfer_leg("cc_payment", payment: true)).name
  end

  test "categoryless loan_payment and investment_contribution keep Uncategorized badge" do
    %w[loan_payment investment_contribution].each do |kind|
      assert_equal Category.uncategorized.name, display_category_for(transfer_leg(kind, payment: true)).name, kind
    end
  end

  private
    def transfer_leg(kind, payment:)
      transfer = Struct.new(:payment) { def payment? = payment }.new(payment)
      transaction = Transaction.new(kind: kind)
      transaction.define_singleton_method(:transfer) { transfer }
      transaction
    end
end
