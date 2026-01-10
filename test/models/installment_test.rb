require "test_helper"

class InstallmentTest < ActiveSupport::TestCase
  test "next_due_date advances with payments" do
    installment = Installment.create!(
      family: families(:dylan_family),
      name: "Laptop",
      total_installments: 3,
      payment_period: "monthly",
      first_payment_date: Date.new(2026, 1, 1),
      installment_cost_cents: 100,
      currency: "USD"
    )

    Entry.create!(
      account: accounts(:depository),
      name: "Installment payment",
      date: Date.new(2026, 1, 1),
      amount: 100,
      currency: "USD",
      entryable: Transaction.new(installment: installment, kind: "installment_payment")
    )

    assert_equal 1, installment.payments_made_count
    assert_equal Date.new(2026, 2, 1), installment.next_due_date
    assert_equal 2, installment.remaining_installments
  end

  test "overdue detects missed scheduled payment" do
    travel_to Date.new(2026, 1, 10) do
      installment = Installment.create!(
        family: families(:dylan_family),
        name: "Phone",
        total_installments: 2,
        payment_period: "weekly",
        first_payment_date: Date.new(2025, 12, 31),
        installment_cost_cents: 50,
        currency: "USD"
      )

      assert installment.overdue?
      refute installment.due_soon?
    end
  end

  test "due_soon when upcoming within window" do
    travel_to Date.new(2026, 1, 1) do
      installment = Installment.create!(
        family: families(:dylan_family),
        name: "Course",
        total_installments: 2,
        payment_period: "monthly",
        first_payment_date: Date.current + 2.days,
        installment_cost_cents: 75,
        currency: "USD"
      )

      assert installment.due_soon?
      refute installment.overdue?
    end
  end

  test "current_month_payment_total uses logged payment" do
    travel_to Date.new(2026, 1, 15) do
      installment = Installment.create!(
        family: families(:dylan_family),
        name: "Subscription",
        total_installments: 2,
        payment_period: "monthly",
        first_payment_date: Date.new(2026, 1, 1),
        installment_cost_cents: 200,
        currency: "USD"
      )

      Entry.create!(
        account: accounts(:depository),
        name: "Installment payment",
        date: Date.new(2026, 1, 1),
        amount: 200,
        currency: "USD",
        entryable: Transaction.new(installment: installment, kind: "installment_payment")
      )

      assert_equal Money.new(200, "USD"), installment.current_month_payment_total
    end
  end
end
