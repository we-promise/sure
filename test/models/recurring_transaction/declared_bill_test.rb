require "test_helper"

class RecurringTransaction::DeclaredBillTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "an unparseable amount becomes a validation error, not an exception" do
    series = build_bill(amount: "$40.00")

    assert_not series.errors.none?
    assert_includes series.errors.full_messages.to_sentence,
      I18n.t("recurring_transactions.create.amount_invalid")
  end

  test "a plain numeric amount still builds" do
    series = build_bill(amount: "40.00")

    assert series.errors.none?
    assert_equal 40, series.amount
  end

  test "the same identity at the same amount reports a duplicate instead of raising" do
    # The first duplicate is legitimized by stamping the amount into
    # dedup_scope; the second collides on that stamp too and must surface as
    # a validation error rather than an escaping RecordNotUnique.
    assert RecurringTransaction::DeclaredBill.save(build_bill(amount: "40"))
    assert RecurringTransaction::DeclaredBill.save(build_bill(amount: "40"))

    duplicate = build_bill(amount: "40")
    assert_not RecurringTransaction::DeclaredBill.save(duplicate)
    assert_includes duplicate.errors.full_messages.to_sentence,
      I18n.t("recurring_transactions.create.already_exists")
  end

  test "the same identity at a different amount forks on the amount" do
    first = build_bill(amount: "40")
    assert RecurringTransaction::DeclaredBill.save(first)

    other_tier = build_bill(amount: "65")
    assert RecurringTransaction::DeclaredBill.save(other_tier),
      "a second tier from the same biller is a legitimate second series"
  end

  private
    def build_bill(amount:)
      RecurringTransaction::DeclaredBill.new(
        family: @family,
        user: @user,
        attrs: {
          name: "Trash Pickup",
          amount: amount,
          account_id: accounts(:depository).id,
          first_due_on: (Date.current + 10).iso8601,
          frequency_preset: "monthly"
        }
      ).build
    end
end
