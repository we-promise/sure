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

    part_ids = vest.vest_parts.pluck(:id).sort
    reopened.assign_attributes(vested_qty: 100, units_withheld: 40,
                               tax_lines: [ { id: reopened.tax_lines.first.id, name: "Federal", category_id: @federal.id, amount: 400 } ])
    assert reopened.save, reopened.errors.full_messages.to_sentence

    vest.reload
    assert_equal 60, vest.trade.qty
    assert_equal 600, vest.amount
    assert_equal [ -1000, 400 ], vest.vest_parts.map(&:amount).sort
    assert_equal part_ids, vest.vest_parts.pluck(:id).sort, "the same entries, updated in place"
  end

  test "saving the vest again keeps what the user added to its income and taxes" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, tax_lines: [ { name: "Federal", amount: 200 }, { name: "State", amount: 100 } ])
    form.save
    federal = form.entry.vest_parts.find { |part| part.name == "Federal" }
    federal.update!(notes: "paystub 2026-11-15")

    reopened = Trade::VestForm.for(form.entry.reload)
    reopened.assign_attributes(price: 11, tax_lines: [ { id: federal.id, name: "Federal", amount: 230 } ])
    assert reopened.save, reopened.errors.full_messages.to_sentence

    federal.reload
    assert_equal "paystub 2026-11-15", federal.notes
    assert_equal 230, federal.amount
    assert_equal [ federal.id ], Trade::VestForm.parts_of(form.entry.reload).last.map(&:id), "the State line is gone"
  end

  test "clearing one tax line keeps the entry of each line left, whatever its position" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, tax_lines: [ { name: "Federal", amount: 200 }, { name: "State", amount: 100 } ])
    form.save
    federal, state = Trade::VestForm.parts_of(form.entry).last
    state.update!(notes: "state paystub line")

    reopened = Trade::VestForm.for(form.entry.reload)
    reopened.assign_attributes(tax_lines: [ { id: federal.id, name: "", amount: "" }, { id: state.id, name: "State", amount: 100 } ])
    assert reopened.save, reopened.errors.full_messages.to_sentence

    assert_equal [ state.id ], Trade::VestForm.parts_of(form.entry.reload).last.map(&:id)
    assert_equal "state paystub line", state.reload.notes
    assert_not Entry.exists?(federal.id)
  end

  test "a tax line's id from another vest is a new line, not that vest's entry" do
    other = vest_form(vested_qty: 10, units_withheld: 3, price: 10)
    other.save
    others_tax = Trade::VestForm.parts_of(other.entry).last.first

    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, tax_lines: [ { id: others_tax.id, name: "Federal", amount: 300 } ])
    assert form.save

    assert_equal 30, others_tax.reload.amount
    assert_not_includes Trade::VestForm.parts_of(form.entry).last.map(&:id), others_tax.id
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

  test "a tax amount must be a number, not just start with one" do
    form = vest_form(vested_qty: 10, price: 25, tax_lines: [ { amount: "300oops" } ])

    assert_not form.save
    assert_includes form.errors[:base], I18n.t("vests.form.tax_amount_required")
    assert vest_form(vested_qty: 10, price: 25, tax_lines: [ { name: "Federal", amount: "0" } ]).save, "zero is an amount"
  end

  test "a vest's shares, income, and taxes can't be changed one at a time" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)
    form.save
    vest = form.entry
    income, (tax, *) = Trade::VestForm.parts_of(vest)

    assert_not vest.update(entryable_attributes: { id: vest.entryable_id, qty: 80 })
    assert_not income.update(amount: -900)
    assert_not tax.update(date: 1.day.ago.to_date)
    assert_not income.update(entryable_attributes: { id: income.entryable_id, investment_activity_label: "Other" })
    assert_not vest.update(entryable_attributes: { id: vest.entryable_id, investment_activity_label: "Buy" })
    assert income.reload.update(notes: "from the paystub"), "notes and other details stay editable"
  end

  test "rules and direct saves can't change a vest part's label, exclusion, or transfer either" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)
    form.save
    income, (tax, *) = Trade::VestForm.parts_of(form.entry)

    assert_not tax.transaction.update(investment_activity_label: "Fee"), "a transaction saved without its entry"
    assert_not tax.transaction.reload.enrich_attribute(:investment_activity_label, "Fee", source: "rule", ignore_locks: true)
    assert_not income.update(excluded: true)

    rule = rules(:one)
    Rule::Action.new(rule: rule, action_type: "set_investment_activity_label", value: "Fee")
                .apply(Transaction.where(id: tax.entryable_id), ignore_attribute_locks: true)
    Rule::Action.new(rule: rule, action_type: "set_as_transfer_or_payment", value: accounts(:depository).id)
                .apply(Transaction.where(id: [ income.entryable_id, tax.entryable_id ]))

    assert_equal Trade::VestForm::TAX_LABEL, tax.transaction.reload.investment_activity_label
    assert_nil income.transaction.reload.transfer
    assert_nil tax.transaction.transfer
  end

  test "the transfer rule still sets up the other transactions it matches" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)
    form.save
    tax = Trade::VestForm.parts_of(form.entry).last.first
    other = @account.entries.create!(name: "Withdrawal", date: Date.current, amount: 50, currency: "USD", entryable: Transaction.new)

    Rule::Action.new(rule: rules(:one), action_type: "set_as_transfer_or_payment", value: accounts(:depository).id)
                .apply(Transaction.where(id: [ tax.entryable_id, other.entryable_id ]))

    assert other.transaction.reload.transfer.present?
  end

  test "two tax lines can't name the same entry" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10, tax_lines: [ { name: "Federal", amount: 300 } ])
    form.save
    federal = Trade::VestForm.parts_of(form.entry).last.first

    reopened = Trade::VestForm.for(form.entry.reload)
    reopened.assign_attributes(tax_lines: [ { id: federal.id, name: "Federal", amount: 200 }, { id: federal.id, name: "State", amount: 100 } ])

    assert_not reopened.save
    assert_includes reopened.errors[:base], I18n.t("vests.form.tax_line_repeated")
    assert vest_form(vested_qty: 100, units_withheld: 30, price: 10, tax_lines: [ { name: "A", amount: 200 }, { name: "B", amount: 100 } ]).save,
      "new lines without ids are fine"
  end

  test "an ordinary trade can't be relabelled as a vest" do
    sell = @account.entries.create!(name: "Sell", date: Date.current, amount: -100, currency: "USD",
                                    entryable: Trade.new(security: securities(:aapl), qty: -1, price: 100, currency: "USD", investment_activity_label: "Sell"))

    assert_not sell.update(entryable_attributes: { id: sell.entryable_id, investment_activity_label: Trade::VEST_LABEL })
    assert_not_includes Transaction::ACTIVITY_LABELS, Trade::VEST_LABEL, "no label menu offers it"
  end

  test "a vest's income and taxes can't be split or matched as transfers" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)
    form.save
    income = Trade::VestForm.parts_of(form.entry).first
    outflow = accounts(:depository).entries.create!(name: "Pay", date: Date.current, amount: 1000, currency: "USD", entryable: Transaction.new)

    assert_not income.transaction.splittable?
    assert_not income.split_once!([ { name: "a", amount: -500 }, { name: "b", amount: -500 } ])

    transfer = Transfer.new(inflow_transaction: income.transaction, outflow_transaction: outflow.transaction)
    assert_not transfer.valid?
    assert_includes transfer.errors[:base], I18n.t("activerecord.errors.models.transfer.vest_part")
  end

  test "auto-matching leaves a vest's income out" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)
    form.save
    income = Trade::VestForm.parts_of(form.entry).first
    accounts(:depository).entries.create!(name: "Pay", date: Date.current, amount: 1000, currency: "USD", entryable: Transaction.new)

    @family.auto_match_transfers!

    assert_nil Transfer.find_by(inflow_transaction_id: income.entryable_id)
    assert_not_includes @family.transfer_match_candidates.map(&:inflow_transaction_id), income.entryable_id
  end

  test "deleting a vest is refused while its income or a tax is a transfer leg" do
    form = vest_form(vested_qty: 100, units_withheld: 30, price: 10)
    form.save
    income = Trade::VestForm.parts_of(form.entry).first
    outflow = accounts(:depository).entries.create!(name: "Pay", date: Date.current, amount: 1000, currency: "USD", entryable: Transaction.new)
    # Recorded past the transfer rules, as an older or raw-SQL path could.
    Transfer.new(inflow_transaction: income.transaction, outflow_transaction: outflow.transaction, status: "confirmed").save!(validate: false)

    assert_no_difference -> { Entry.count } do
      assert_raises(Entry::SplitPartTransferredError) { form.entry.destroy_unless_split_part_transferred! }
    end
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
