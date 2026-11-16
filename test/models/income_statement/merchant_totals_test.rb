require "test_helper"

class IncomeStatement::MerchantTotalsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @user = users(:empty)
    @checking = @family.accounts.create! name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new, owner: @user
    @savings = @family.accounts.create! name: "Savings", currency: @family.currency, balance: 5000, accountable: Depository.new, owner: @user

    @month = 1.month.ago.to_date
    @period = Period.custom(start_date: @month.beginning_of_month, end_date: @month.end_of_month)
    @day = @month.beginning_of_month + 10.days

    @amazon = @family.merchants.create!(name: "Amazon")
    @coffee = @family.merchants.create!(name: "Coffee Co")
  end

  test "ranks merchants by net spending" do
    create_example_rows

    rows = merchant_totals

    assert_equal [ "Amazon", "Coffee Co", nil ], rows.map(&:name)
    assert_row rows.first, net: 70, purchases_count: 2, average: 50
    assert_row rows.second, net: 13.5, purchases_count: 3, average: 4.5
  end

  test "folds same-named family and provider merchants into one row" do
    provider_coffee = ProviderMerchant.create!(name: "Coffee Co", source: "plaid")
    spend(4.5, merchant: @coffee)
    spend(4.5, merchant: provider_coffee)

    rows = merchant_totals

    assert_equal [ "Coffee Co" ], rows.map(&:name)
    assert_row rows.first, net: 9, purchases_count: 2, average: 4.5
  end

  test "reports spending with no merchant as its own row" do
    create_example_rows

    no_merchant = merchant_totals.find { |row| row.name.nil? }

    assert_not_nil no_merchant
    assert_row no_merchant, net: 25, purchases_count: 1, average: 25
  end

  test "the no merchant row counts spending only, not income without a merchant" do
    spend(25)
    spend(-3000)

    no_merchant = merchant_totals.find { |row| row.name.nil? }

    assert_not_nil no_merchant
    assert_row no_merchant, net: 25, purchases_count: 1, average: 25
  end

  test "lists the no merchant row after the named merchants" do
    spend(500)
    spend(10, merchant: @amazon)

    assert_equal [ "Amazon", nil ], merchant_totals.map(&:name)
  end

  test "converts foreign-currency rows to the family currency" do
    eur = @family.accounts.create! name: "EUR Checking", currency: "EUR", balance: 1000, accountable: Depository.new, owner: @user
    ExchangeRate.create! from_currency: "EUR", to_currency: @family.currency, date: @day, rate: 2
    spend(10, merchant: @amazon, account: eur, currency: "EUR")

    assert_row merchant_totals.first, net: 20, purchases_count: 1, average: 20
  end

  test "leaves a purchase with no exchange rate out of the count as well as the total" do
    yen = @family.accounts.create! name: "JPY Card", currency: "JPY", balance: 0, accountable: Depository.new, owner: @user
    spend(10, merchant: @amazon)
    spend(1000, merchant: @amazon, account: yen, currency: "JPY")

    assert_row merchant_totals.first, net: 10, purchases_count: 1, average: 10
  end

  test "counts a split purchase once" do
    spend(40, merchant: @amazon)
    split_me = spend(60, merchant: @amazon)
    spend(-30, merchant: @amazon)
    split_me.split!([ { name: "Part one", amount: 35 }, { name: "Part two", amount: 25 } ])

    assert_row merchant_totals.first, net: 70, purchases_count: 2, average: 50
  end

  test "agrees with the headline expense total" do
    disabled = @family.accounts.create! name: "Old card", currency: @family.currency, balance: 0, accountable: CreditCard.new, owner: @user
    spend(40, merchant: @amazon)
    spend(25)
    spend(15, account: disabled, merchant: @amazon)
    sweep = spend(70, merchant: @coffee)
    sweep.entryable.update!(investment_activity_label: "Sweep In")
    spend(-200, kind: "investment_contribution")
    refund_only = @family.merchants.create!(name: "Refund Shop")
    spend(-12, merchant: refund_only)
    spend(8, merchant: refund_only)
    disabled.disable!

    statement = IncomeStatement.new(@family, user: @user)
    all_rows = IncomeStatement::MerchantTotals.new(
      @family,
      transactions_scope: @family.transactions.visible.excluding_pending.merge(Entry.excluding_scheduled).in_period(@period),
      date_range: @period.date_range,
      included_account_ids: @user.finance_accounts.pluck(:id)
    ).call

    assert_includes all_rows.map(&:name), "Refund Shop"

    assert_equal 273, statement.expense_totals(period: @period).total
    assert_equal statement.expense_totals(period: @period).total, all_rows.sum(&:purchases)
  end

  test "leaves out transfers, card payments and one-time kinds" do
    spend(10, merchant: @amazon)
    Transaction::BUDGET_EXCLUDED_KINDS.each do |kind|
      spend(100, merchant: @amazon, kind: kind)
    end

    assert_row merchant_totals.first, net: 10, purchases_count: 1, average: 10
  end

  test "leaves out excluded entries" do
    spend(10, merchant: @amazon)
    spend(100, merchant: @amazon, excluded: true)

    assert_row merchant_totals.first, net: 10, purchases_count: 1, average: 10
  end

  test "leaves out accounts excluded from reports, tax-advantaged, disabled or pending deletion" do
    spend(10, merchant: @amazon)

    hidden = @family.accounts.create! name: "Hidden", currency: @family.currency, balance: 0, accountable: Depository.new, owner: @user, exclude_from_reports: true
    retirement = @family.accounts.create! name: "401k", currency: @family.currency, balance: 0, accountable: Investment.new(subtype: "401k"), owner: @user
    disabled = @family.accounts.create! name: "Disabled", currency: @family.currency, balance: 0, accountable: Depository.new, owner: @user
    deleting = @family.accounts.create! name: "Deleting", currency: @family.currency, balance: 0, accountable: Depository.new, owner: @user
    [ hidden, retirement, disabled, deleting ].each { |account| spend(100, merchant: @amazon, account: account) }
    disabled.disable!
    deleting.mark_for_deletion!

    assert_row merchant_totals.first, net: 10, purchases_count: 1, average: 10
  end

  # IncomeStatement passes a scope already limited to the family's visible
  # accounts; the query applies both limits itself too, as Totals does.
  test "keeps to the family's visible accounts whatever scope it is given" do
    disabled = @family.accounts.create! name: "Disabled", currency: @family.currency, balance: 0, accountable: Depository.new, owner: @user
    other_family = families(:dylan_family)
    other_account = other_family.accounts.create! name: "Theirs", currency: other_family.currency, balance: 0, accountable: Depository.new
    spend(10, merchant: @amazon)
    spend(100, merchant: @amazon, account: disabled)
    spend(100, merchant: other_family.merchants.find_or_create_by!(name: "Amazon"), account: other_account)
    disabled.disable!

    rows = IncomeStatement::MerchantTotals.new(@family, transactions_scope: Transaction.all, date_range: @period.date_range).call

    assert_equal 10, rows.find { |row| row.name == "Amazon" }.purchases
  end

  test "leaves out investment activity that moves money within a portfolio" do
    spend(10, merchant: @amazon)
    [ "Transfer", "Sweep In", "Sweep Out", "Exchange" ].each do |label|
      spend(100, merchant: @amazon).entryable.update!(investment_activity_label: label)
    end

    assert_row merchant_totals.first, net: 10, purchases_count: 1, average: 10
  end

  test "leaves out pending rows" do
    spend(10, merchant: @amazon)
    spend(100, merchant: @amazon).entryable.update!(extra: { "simplefin" => { "pending" => true } })

    assert_row merchant_totals.first, net: 10, purchases_count: 1, average: 10
  end

  test "leaves out accounts outside the user's finances" do
    other = @family.accounts.create! name: "Partner's", currency: @family.currency, balance: 0, accountable: Depository.new, owner: users(:sure_support_staff)
    spend(10, merchant: @amazon)
    spend(100, merchant: @amazon, account: other)

    assert_row merchant_totals.first, net: 10, purchases_count: 1, average: 10
  end

  test "leaves out merchants whose net is not spending" do
    employer = @family.merchants.create!(name: "Employer")
    refund_only = @family.merchants.create!(name: "Refund Shop")
    spend(10, merchant: @amazon)
    spend(-3000, merchant: employer)
    spend(-20, merchant: refund_only)
    spend(20, merchant: @coffee)
    spend(-20, merchant: @coffee)

    assert_equal [ "Amazon" ], merchant_totals.map(&:name)
  end

  test "counts the first and last day of the period and nothing either side" do
    spend(1, merchant: @amazon, date: @period.start_date)
    spend(2, merchant: @amazon, date: @period.end_date)
    spend(100, merchant: @amazon, date: @period.start_date - 1.day)
    spend(100, merchant: @amazon, date: @period.end_date + 1.day)

    assert_row merchant_totals.first, net: 3, purchases_count: 2, average: 1.5
  end

  test "leaves out another family's spending at a same-named merchant" do
    other_family = families(:dylan_family)
    other_account = other_family.accounts.create! name: "Theirs", currency: other_family.currency, balance: 0, accountable: Depository.new
    other_amazon = other_family.merchants.find_or_create_by!(name: "Amazon")
    spend(10, merchant: @amazon)
    spend(100, merchant: other_amazon, account: other_account)

    assert_row merchant_totals.first, net: 10, purchases_count: 1, average: 10
  end

  test "a merchant's net and purchases match its transactions drill-down" do
    split_me = create_example_rows
    split_me.split!([ { name: "Part one", amount: 35 }, { name: "Part two", amount: 25 } ])

    amazon = merchant_totals.find { |row| row.name == "Amazon" }
    listed = Transaction::Search.new(@family, filters: {
      "merchants" => [ "Amazon" ],
      "start_date" => @period.start_date.to_s,
      "end_date" => @period.end_date.to_s
    }).transactions_scope.where.not(kind: Transaction::BUDGET_EXCLUDED_KINDS).map(&:entry)
    purchases = listed.select { |entry| entry.amount.positive? }

    assert_equal 3, purchases.size
    assert_equal amazon.net, listed.sum(&:amount)
    assert_equal amazon.purchases_count, purchases.map { |entry| entry.parent_entry_id || entry.id }.uniq.size
  end

  private
    def merchant_totals
      IncomeStatement.new(@family, user: @user).merchant_totals(period: @period)
    end

    def spend(amount, merchant: nil, account: @checking, date: @day, **attributes)
      create_transaction(account: account, amount: amount, date: date, merchant: merchant, currency: account.currency, **attributes)
    end

    # Amazon 40 + 60 - 30, Coffee Co 3 x 4.50, a transfer and 25 with no
    # merchant. Returns the 60 purchase so a test can split it.
    def create_example_rows
      spend(40, merchant: @amazon)
      sixty = spend(60, merchant: @amazon)
      spend(-30, merchant: @amazon)
      3.times { spend(4.5, merchant: @coffee) }
      create_transfer(from_account: @checking, to_account: @savings, amount: 500, date: @day)
      spend(25)
      sixty
    end

    def assert_row(row, net:, purchases_count:, average:)
      assert_equal net.to_d, row.net.to_d, "net for #{row.name.inspect}"
      assert_equal purchases_count, row.purchases_count, "purchases for #{row.name.inspect}"
      assert_equal average.to_d, row.average.to_d.round(2), "average for #{row.name.inspect}"
    end
end
