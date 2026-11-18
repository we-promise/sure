require "test_helper"

class WiseItem::RefundCategorizerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(family: @family, name: "Test Wise", token: "test_token", profile_id: "123", profile_type: :business)
    wise_account = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR", current_balance: 0,
                                                    raw_payload: { "type" => "STANDARD" })
    @account = Account.create!(family: @family, name: "Wise EUR", balance: 0, currency: "EUR",
                               accountable: Depository.new(subtype: "checking"))
    AccountProvider.create!(account: @account, provider: wise_account)
    @shopping = @family.categories.create!(name: "Shopping", color: "#123456", lucide_icon: "shopping-bag")
  end

  test "gives a full card refund the category of its purchase" do
    purchase = card_payment("Mgp*Vinted Vilnius", 21.94, Date.new(2026, 9, 26), category: @shopping)
    refund = card_refund("Vinted", 21.94, Date.new(2026, 10, 21))

    assert_equal 1, WiseItem::RefundCategorizer.new(@wise_item).categorize!
    assert_equal @shopping, refund.reload.category
    assert_equal @shopping, purchase.reload.category
  end

  test "leaves a partial refund alone" do
    card_payment("Wallapop", 25.34, Date.new(2026, 9, 15), category: @shopping)
    refund = card_refund("Wallapop", 10, Date.new(2026, 9, 23))

    assert_equal 0, WiseItem::RefundCategorizer.new(@wise_item).categorize!
    assert_nil refund.reload.category
  end

  test "leaves a refund that could be any of several purchases alone" do
    card_payment("Wallapop", 6.74, Date.new(2026, 9, 1), category: @shopping)
    card_payment("Wallapop", 6.74, Date.new(2026, 9, 3), category: @shopping)
    refund = card_refund("Wallapop", 6.74, Date.new(2026, 9, 6))

    assert_equal 0, WiseItem::RefundCategorizer.new(@wise_item).categorize!
    assert_nil refund.reload.category
  end

  test "does not change a refund whose category is locked" do
    card_payment("Wallapop", 6.74, Date.new(2026, 9, 5), category: @shopping)
    refund = card_refund("Wallapop", 6.74, Date.new(2026, 9, 6))
    refund.lock_attr!(:category_id)

    assert_equal 0, WiseItem::RefundCategorizer.new(@wise_item).categorize!
    assert_nil refund.reload.category
  end

  private
    def card_payment(name, amount, date, category:)
      wise_transaction(name, amount, date, category: category, extra: { "activity_type" => "CARD_PAYMENT" })
    end

    def card_refund(name, amount, date)
      wise_transaction(name, -amount, date, extra: { "activity_type" => "CARD_PAYMENT", "description" => "Refunded" })
    end

    def wise_transaction(name, amount, date, extra:, category: nil)
      entry = @account.entries.create!(name: name, amount: amount, currency: "EUR", date: date, source: "wise",
                                       external_id: "wise_activity_#{SecureRandom.hex(4)}",
                                       entryable: Transaction.new(category: category, extra: { "wise" => extra }))
      entry.entryable
    end
end
