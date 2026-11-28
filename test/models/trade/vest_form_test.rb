require "test_helper"

class Trade::VestFormTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @family = @account.family
    @pay = @family.categories.create!(name: "RSU income")
    @federal = @family.categories.create!(name: "Federal tax")
    @state = @family.categories.create!(name: "State tax")
  end

  # 100 vested at 10: 70 received, 30 withheld for taxes paid as two lines.
  test "a vest is the shares, the gross pay as income, and each tax line, with no cash left" do
    form = vest_form(
      vested_qty: 100, units_withheld: 30, price: 10, income_category_id: @pay.id,
      tax_lines: [ { name: "Federal income tax", category_id: @federal.id, amount: 220 }, { name: "State income tax", category_id: @state.id, amount: 80 } ]
    )

    assert_difference -> { @account.entries.count }, 4 do
      assert form.save, form.errors.full_messages.to_sentence
    end

    vest = form.entry
    assert_equal Trade::VEST_LABEL, vest.trade.investment_activity_label
    assert_equal 70, vest.trade.qty
    assert_equal 30, vest.trade.units_withheld
    assert_equal 700, vest.amount, "the shares are paid for from the pay, as a buy is"

    income = vest.vest_parts.find { |part| part.amount.negative? }
    assert_equal(-1000, income.amount)
    assert_equal @pay, income.transaction.category
    assert_equal Trade::VestForm::INCOME_LABEL, income.transaction.investment_activity_label
    assert_equal "AAPL vest income", income.name

    taxes = vest.vest_parts.select { |part| part.amount.positive? }.sort_by(&:amount)
    assert_equal [ 80, 220 ], taxes.map(&:amount)
    assert_equal [ @state, @federal ], taxes.map { |tax| tax.transaction.category }
    assert_equal [ Trade::VestForm::TAX_LABEL ], taxes.map { |tax| tax.transaction.investment_activity_label }.uniq
    assert_equal "Federal income tax", taxes.last.name

    assert_equal 0, form.cash_left
    assert_equal 0, @account.entries.where(id: [ vest.id, *vest.vest_parts.map(&:id) ]).sum(:amount)
  end

  test "with no tax lines, the withheld shares' value is one tax line" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)

    assert form.save, form.errors.full_messages.to_sentence

    taxes = form.entry.vest_parts.select { |part| part.amount.positive? }
    assert_equal [ 300 ], taxes.map(&:amount)
    assert_equal "Taxes withheld", taxes.first.name
  end

  test "with nothing withheld and no tax lines, there is only the income" do
    form = vest_form(vested_qty: 10, price: 25)

    assert form.save, form.errors.full_messages.to_sentence
    assert_equal [ -250 ], form.entry.vest_parts.map(&:amount)
  end

  test "taxes that differ from the withheld shares leave the difference as cash" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, tax_lines: [ { name: "Federal", amount: 280 } ])

    assert form.save
    assert_equal 20, form.cash_left
  end

  test "a category from another family is no category" do
    other = families(:empty).categories.create!(name: "Not theirs")
    form = vest_form(vested_qty: 10, price: 25, income_category_id: other.id)

    assert form.save
    assert_nil form.entry.vest_parts.first.transaction.category
  end

  test "reopening a vest fills the form from its entries, and saving replaces them" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, income_category_id: @pay.id,
                     tax_lines: [ { name: "Federal", category_id: @federal.id, amount: 300 } ])
    form.save
    vest = form.entry

    reopened = Trade::VestForm.for(vest.reload)
    assert_equal 100, reopened.vested_qty
    assert_equal 30, reopened.units_withheld
    assert_equal @pay.id, reopened.income_category_id
    assert_equal [ [ "Federal", @federal.id, 300 ] ], reopened.tax_lines.map { |line| [ line.name, line.category_id, line.amount ] }

    reopened.assign_attributes(vested_qty: 100, units_withheld: 40, tax_lines: [ { name: "Federal", category_id: @federal.id, amount: 400 } ])
    assert_no_difference -> { @account.entries.count } do
      assert reopened.save, reopened.errors.full_messages.to_sentence
    end

    vest.reload
    assert_equal 60, vest.trade.qty
    assert_equal 600, vest.amount
    assert_equal [ -1000, 400 ], vest.vest_parts.map(&:amount).sort
  end

  test "saving the vest again keeps what the user added to its income and taxes" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, tax_lines: [ { name: "Federal", amount: 200 }, { name: "State", amount: 100 } ])
    form.save
    federal = form.entry.vest_parts.find { |part| part.name == "Federal" }
    federal.update!(notes: "paystub 2026-11-15")

    reopened = Trade::VestForm.for(form.entry.reload)
    reopened.assign_attributes(price: 11, tax_lines: [ { name: "Federal", amount: 230 } ])
    assert reopened.save, reopened.errors.full_messages.to_sentence

    federal.reload
    assert_equal "paystub 2026-11-15", federal.notes
    assert_equal 230, federal.amount
    assert_equal [ federal.id ], Trade::VestForm.parts_of(form.entry.reload).last.map(&:id), "the State line is gone"
  end

  test "some vested shares must reach the account" do
    form = vest_form(vested_qty: 30, units_withheld: 30, price: 10)

    assert_not form.save
    assert_includes form.errors[:base], I18n.t("vests.form.withheld_exceeds_vested")
  end

  test "a tax line needs an amount, and it cannot be negative" do
    missing = vest_form(vested_qty: 10, price: 25, tax_lines: [ { name: "Federal", amount: "" } ])
    assert_not missing.save
    assert_includes missing.errors[:base], I18n.t("vests.form.tax_amount_required")

    negative = vest_form(vested_qty: 10, price: 25, tax_lines: [ { name: "Federal", amount: -5 } ])
    assert_not negative.save
    assert_includes negative.errors[:base], I18n.t("vests.form.tax_amount_negative")
  end

  test "deleting a vest deletes its income and taxes" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)
    form.save

    assert_difference -> { @account.entries.count }, -3 do
      form.entry.destroy!
    end
  end

  test "a vest needs shares, a price, and an investment account" do
    assert_not vest_form(vested_qty: 0, price: 10).save
    assert_not vest_form(vested_qty: 10, price: "").save

    checking = Trade::VestForm.new(account: accounts(:depository), date: Date.current, manual_ticker: "AAPL", vested_qty: 10, price: 10)
    assert_not checking.save
    assert_includes checking.errors[:base], I18n.t("vests.form.investment_account_required")
  end

  test "nothing is saved when one of the entries fails" do
    Transaction.any_instance.stubs(:valid?).returns(false)
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)

    assert_no_difference -> { Entry.count } do
      assert_not form.save
    end
    assert form.errors[:base].any?
  end

  test "the vest's shares are internal to the returns, its income is money in and its taxes money out" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)
    form.save
    classifier = Portfolio::FlowClassifier.new(scope_account_ids: [ @account.id ])
    income, tax = form.entry.vest_parts.sort_by(&:amount)

    assert_equal :internal, classifier.classify(form.entry)
    assert_equal :external_inflow, classifier.classify(income)
    assert_equal :external_outflow, classifier.classify(tax)
  end

  test "the cash flow counts the gross pay as income and each tax as spending in its category" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, income_category_id: @pay.id,
                     tax_lines: [ { name: "Federal", category_id: @federal.id, amount: 220 }, { name: "State", category_id: @state.id, amount: 80 } ])
    form.save
    statement = IncomeStatement.new(@family)
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)

    income = statement.income_totals(period: period).category_totals.find { |ct| ct.category.id == @pay.id }
    expenses = statement.expense_totals(period: period).category_totals

    assert_equal 1000, income.total
    assert_equal 220, expenses.find { |ct| ct.category.id == @federal.id }.total
    assert_equal 80, expenses.find { |ct| ct.category.id == @state.id }.total
  end

  test "the lot costs the price the shares vested at" do
    # A ticker the account holds no other shares of, so nothing averages in.
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, manual_ticker: "VESTONLY")
    form.save

    holding = Holding::ForwardCalculator.new(@account).calculate
      .find { |h| h.security_id == form.entry.trade.security_id && h.date == Date.current }

    assert_equal 10, holding.cost_basis
  end

  private
    def vest_form(**attrs)
      Trade::VestForm.new(**{ account: @account, date: Date.current, manual_ticker: "AAPL" }.merge(attrs))
    end
end
