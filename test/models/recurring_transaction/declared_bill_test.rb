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

  test "a non-finite amount becomes a validation error, not a saved bill" do
    %w[Infinity -Infinity NaN].each do |value|
      series = build_bill(amount: value)

      assert_not series.errors.none?, "#{value} must not build a valid bill"
      assert_includes series.errors.full_messages.to_sentence,
        I18n.t("recurring_transactions.create.amount_invalid")
    end
  end

  # The form offers the currency next to the amount, like a transaction's: a
  # USD subscription charged to a EUR card is a USD bill.
  test "a picked currency wins over the account's" do
    series = build_bill(amount: "40", currency: "EUR")

    assert series.errors.none?
    assert_equal "EUR", series.currency
    assert_equal "USD", accounts(:depository).currency
  end

  test "without a picked currency the bill takes its account's" do
    assert_equal accounts(:depository).currency, build_bill(amount: "40").currency
    assert_equal accounts(:depository).currency, build_bill(amount: "40", currency: "").currency
  end

  test "a currency the app doesn't know is ignored, not saved" do
    series = build_bill(amount: "40", currency: "XYZ")

    assert series.errors.none?
    assert_equal accounts(:depository).currency, series.currency
  end

  # The column keeps four decimal places. A finer amount would be rounded on
  # save, and one this small to zero: a bill whose cycles can never close.
  test "an amount finer than the column keeps is refused, not rounded" do
    series = build_bill(amount: "0.00000001", currency: "BTC")

    assert_includes series.errors.full_messages.to_sentence,
      I18n.t("recurring_transactions.create.amount_too_precise")
    assert build_bill(amount: "12.3456", currency: "BTC").errors.none?
  end

  # The assistant sends JSON numbers, so 15.99 + 1 arrives as
  # 16.990000000000002. That is noise past any currency's places, not a
  # precision the user meant, and it saves as 16.99 the way it always has.
  test "float noise past every currency's places is rounded, not refused" do
    series = build_bill(amount: (15.99 + 1).to_s)

    assert series.errors.none?, series.errors.full_messages.to_sentence
    assert_equal BigDecimal("16.99"), series.amount
  end

  test "the same identity at the same amount reports a duplicate instead of raising" do
    # The amount is stamped into dedup_scope before the first insert, so the
    # very first identical duplicate collides and must surface as a validation
    # error rather than an escaping RecordNotUnique.
    assert RecurringTransaction::DeclaredBill.save(build_bill(amount: "40"))

    duplicate = build_bill(amount: "40")
    assert_not RecurringTransaction::DeclaredBill.save(duplicate)
    assert_includes duplicate.errors.full_messages.to_sentence,
      I18n.t("recurring_transactions.create.already_exists")
    assert_equal 1, @family.recurring_transactions.where(name: "Trash Pickup").count
  end

  test "the same identity at a different amount forks on the amount" do
    first = build_bill(amount: "40")
    assert RecurringTransaction::DeclaredBill.save(first)

    other_tier = build_bill(amount: "65")
    assert RecurringTransaction::DeclaredBill.save(other_tier),
      "a second tier from the same biller is a legitimate second series"
  end

  private
    def build_bill(amount:, **attrs)
      RecurringTransaction::DeclaredBill.new(
        family: @family,
        user: @user,
        attrs: {
          name: "Trash Pickup",
          amount: amount,
          account_id: accounts(:depository).id,
          first_due_on: (Date.current + 10).iso8601,
          frequency_preset: "monthly"
        }.merge(attrs)
      ).build
    end
end
