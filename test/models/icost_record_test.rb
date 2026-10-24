require "test_helper"
require "csv"

class IcostRecordTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    Balance::Materializer.any_instance.stubs(:materialize_balances)
  end

  test "ordinary expense and income retain exact amounts and category hierarchy" do
    expense = prepare("金额" => "-12.3456", "标签" => "#Synthetic one#Synthetic two")
    income = prepare("类型" => "收入", "金额" => "20.0100", "备注" => "Synthetic income")
    Account::MarketDataImporter.any_instance.expects(:import_all).never
    Family.any_instance.expects(:auto_match_transfers!).never

    [ expense, income ].each { |record| record.icost_import.publish!(user: @user) }
    assert_equal BigDecimal("12.3456"), expense.reload.entry.amount
    assert_equal BigDecimal("-20.0100"), income.reload.entry.amount
    assert_equal "USD", expense.entry.currency
    assert_equal "Synthetic leaf", expense.entry.transaction.category.name
    assert_equal "Synthetic root", expense.entry.transaction.category.parent.name
    assert_equal [ "Synthetic one", "Synthetic two", "iCost账本：Synthetic book" ].sort, expense.entry.transaction.tags.pluck(:name).sort
    assert_equal "Synthetic note", expense.entry.notes
    assert_equal "standard", expense.entry.transaction.kind
  end

  test "foreign currency stays in its own account without conversion or rate lookup" do
    euro_account = @family.accounts.create!(name: "Synthetic EUR account", owner: @user,
      currency: "EUR", balance: 0, accountable: Depository.new)
    record = prepare("货币" => "EUR", "账户1" => euro_account.name, "金额" => "-17.23")
    Account::MarketDataImporter.any_instance.expects(:import_all).never
    record.icost_import.publish!(user: @user)

    assert_equal "published", record.reload.status
    assert_equal "EUR", record.entry.currency
    assert_equal euro_account.id, record.entry.account_id
    assert_equal BigDecimal("17.23"), record.entry.amount
    assert_equal "EUR", record.currency
    assert_equal BigDecimal("-17.23"), record.amount
  end

  test "mixed currency account is held for review before any balance materialization" do
    Balance::Materializer.any_instance.unstub(:materialize_balances)
    @account.entries.create!(name: "Synthetic foreign transaction", date: "2024-01-01", amount: 3, currency: "EUR",
      entryable: Transaction.new(kind: "standard"))
    before_balance = @account.reload.attributes.slice("balance", "cash_balance")
    ExchangeRate.expects(:find_or_fetch_rate).never

    assert_no_difference [ "Entry.count", "Balance.count", "Holding.count" ] do
      record = prepare
      assert_equal "needs_review", record.status
      assert_includes record.issues, "account_valuation_requires_review"
      record.icost_import.publish!(user: @user)
      assert_nil record.reload.entry_id
    end
    assert_equal before_balance, @account.reload.attributes.slice(*before_balance.keys)
  end

  test "a trade added after preview prevents publishing and leaves balances untouched" do
    Balance::Materializer.any_instance.unstub(:materialize_balances)
    record = prepare
    assert_equal "ready", record.status
    @account.entries.create!(name: "Synthetic security purchase", date: "2024-01-01", amount: 3, currency: "USD",
      entryable: Trade.new(security: securities(:aapl), qty: 1, price: 3, currency: "USD"))
    before_balance = @account.reload.attributes.slice("balance", "cash_balance")
    ExchangeRate.expects(:find_or_fetch_rate).never

    assert_no_difference [ "Entry.count", "Balance.count", "Holding.count", "Trade.count" ] do
      record.icost_import.publish!(user: @user)
    end
    assert_equal "needs_review", record.reload.status
    assert_includes record.issues, "account_valuation_requires_review"
    assert_nil record.entry_id
    assert_equal before_balance, @account.reload.attributes.slice(*before_balance.keys)
  end

  test "resolving an account with holdings preserves review status without fetching prices or rates" do
    Balance::Materializer.any_instance.unstub(:materialize_balances)
    record = prepare("账户1" => "")
    @account.holdings.create!(security: securities(:aapl), date: "2024-01-01", qty: 1, price: 3, amount: 3, currency: "USD")
    before_balance = @account.reload.attributes.slice("balance", "cash_balance")
    ExchangeRate.expects(:find_or_fetch_rate).never

    assert_no_difference [ "Entry.count", "Balance.count", "Holding.count" ] do
      record.resolve!(user: @user, attributes: { account_id: @account.id })
      assert_equal "needs_review", record.reload.status
      assert_includes record.issues, "account_valuation_requires_review"
      record.icost_import.publish!(user: @user)
      assert_nil record.reload.entry_id
    end
    assert_equal before_balance, @account.reload.attributes.slice(*before_balance.keys)
  end

  test "unsupported precision stays exact in source and is not rounded into ledger" do
    record = prepare("金额" => "-0.00001")
    assert_equal BigDecimal("-0.00001"), record.amount
    assert_equal "-0.00001", record.raw_fields["金额"]
    assert_equal "needs_review", record.status
    assert_includes record.issues, "amount_precision_unsupported"
    assert_no_difference("Entry.count") { record.icost_import.publish!(user: @user) }
  end

  test "missing account can be explicitly resolved without altering original source or publishing" do
    record = prepare("账户1" => "")
    original = record.attributes.slice("raw_fields", "source_values", "row_sha256", "source_id", "account_name")
    assert_includes record.issues, "account_required"
    assert_no_difference "Entry.count" do
      record.resolve!(user: @user, attributes: { account_id: @account.id, review_note: "Confirmed synthetic account" })
    end
    assert_equal "ready", record.reload.status
    assert_equal original, record.attributes.slice(*original.keys)
    assert_equal "Confirmed synthetic account", record.review_note
    assert_equal @account.id, record.resolution["account_id"]
    assert_difference "Entry.count", 1 do
      record.icost_import.publish!(user: @user)
    end
    assert_equal @account.id, record.reload.entry.account_id
  end

  test "account resolution rejects other owners and cross-currency accounts" do
    record = prepare("账户1" => "")
    private_account = @family.accounts.create!(name: "Other member synthetic account", owner: users(:family_member),
      currency: "USD", balance: 0, accountable: Depository.new)
    euro_account = @family.accounts.create!(name: "Synthetic EUR account", owner: @user,
      currency: "EUR", balance: 0, accountable: Depository.new)
    [ private_account, euro_account ].each do |account|
      before = record.reload.attributes
      assert_raises(IcostRecord::ResolutionError) do
        record.resolve!(user: @user, attributes: { account_id: account.id })
      end
      assert_equal before, record.reload.attributes
    end
  end

  test "non-owner cannot resolve or publish or change a source record" do
    record = prepare("账户1" => "")
    before = record.attributes
    assert_no_difference "Entry.count" do
      assert_raises(IcostRecord::ResolutionError) do
        record.resolve!(user: users(:family_member), attributes: { review_note: "Unauthorized" })
      end
      assert_raises(IcostRecord::ResolutionError) { record.publish!(user: users(:family_member)) }
    end
    assert_equal before, record.reload.attributes
  end

  test "refund fee discount and installment records stay out of cashflow after account review" do
    rows = [
      [ { "退款" => "2.00" }, "refund_semantics_required" ],
      [ { "优惠" => "2.00" }, "discount_semantics_required" ],
      [ { "手续费" => "2.00" }, "fee_semantics_required" ],
      [ { "类型" => "退款入账", "金额" => "2.00" }, "refund_link_required" ],
      [ { "类型" => "转账", "一级分类" => "分期创建", "二级分类" => "", "金额" => "12.34" }, "installment_details_required" ]
    ]
    assert_no_difference [ "Entry.count", "Transfer.count" ] do
      rows.each do |fields, issue|
        record = prepare(fields)
        record.resolve!(user: @user, attributes: { account_id: @account.id, review_note: "Needs source evidence" })
        assert_equal "needs_review", record.reload.status
        assert_includes record.issues, issue
        record.icost_import.publish!(user: @user)
        assert_nil record.reload.entry_id
      end
    end
  end

  test "explicit transfer creates two linked opposite legs excluded from income and expenses" do
    destination = @family.accounts.create!(name: "Synthetic savings", owner: @user, currency: "USD", balance: 0,
      accountable: Depository.new, status: "active")
    record = prepare("类型" => "转账", "金额" => "125.50", "账户2" => destination.name)
    assert_includes record.issues, "transfer_direction_required"
    assert_no_difference "Entry.count" do
      record.resolve!(user: @user, attributes: { from_account_id: @account.id, to_account_id: destination.id })
    end
    assert_equal "ready", record.reload.status
    assert_difference({ "Entry.count" => 2, "Transfer.count" => 1 }) do
      record.icost_import.publish!(user: @user)
    end
    record.reload
    assert_equal BigDecimal("125.50"), record.entry.amount
    assert_equal BigDecimal("-125.50"), record.counterpart_entry.amount
    assert_equal @account.id, record.entry.account_id
    assert_equal destination.id, record.counterpart_entry.account_id
    assert record.entry.transaction.transfer.confirmed?
    assert_equal record.entry.transaction.transfer, record.counterpart_entry.transaction.transfer
    totals = IncomeStatement.new(@family, user: @user).totals(
      transactions_scope: Transaction.where(id: [ record.entry.entryable_id, record.counterpart_entry.entryable_id ]),
      date_range: Date.new(2024, 1, 2)..Date.new(2024, 1, 2))
    assert_equal 0, totals.income_money.amount
    assert_equal 0, totals.expense_money.amount
    assert_no_difference([ "Entry.count", "Transfer.count" ]) { record.icost_import.publish!(user: @user) }
  end

  test "credit card transfer preserves native payment classification without provider jobs" do
    destination = accounts(:credit_card)
    record = prepare("类型" => "转账", "金额" => "125.50", "账户2" => destination.name)
    record.resolve!(user: @user, attributes: { from_account_id: @account.id, to_account_id: destination.id })

    assert_no_enqueued_jobs only: SyncJob do
      record.icost_import.publish!(user: @user)
    end
    assert_equal "published", record.reload.status
    assert_equal "cc_payment", record.entry.transaction.kind
    assert_equal "funds_movement", record.counterpart_entry.transaction.kind
    assert record.entry.transaction.transfer.confirmed?
  end

  test "explicit income and expense cannot be silently reclassified by transfer auto matching" do
    destination = @family.accounts.create!(name: "Synthetic savings", owner: @user, currency: "USD", balance: 0,
      accountable: Depository.new, status: "active")
    expense = prepare("金额" => "-987.65")
    income = prepare("类型" => "收入", "金额" => "987.65", "账户1" => destination.name)
    [ expense, income ].each { |record| record.icost_import.publish!(user: @user) }

    @family.auto_match_transfers!(account: @account)

    [ expense, income ].each do |record|
      assert_equal "standard", record.reload.entry.transaction.kind
      assert_nil record.entry.transaction.transfer
    end
  end

  test "transfer cannot resolve to the same account or guess another currency" do
    euro_account = @family.accounts.create!(name: "Synthetic EUR account", owner: @user,
      currency: "EUR", balance: 0, accountable: Depository.new)
    record = prepare("类型" => "转账", "金额" => "125.50")
    assert_raises(IcostRecord::ResolutionError) do
      record.resolve!(user: @user, attributes: { from_account_id: @account.id, to_account_id: @account.id })
    end
    assert_raises(IcostRecord::ResolutionError) do
      record.resolve!(user: @user, attributes: { from_account_id: @account.id, to_account_id: euro_account.id })
    end
    assert_equal "needs_review", record.reload.status
    assert_empty record.resolution
    assert_nil record.entry_id
  end

  test "same leaf under another category remains reviewable without flattening or partial writes" do
    original_root = @family.categories.create!(name: "Existing root", color: Category::COLORS.first, lucide_icon: "circle")
    leaf = @family.categories.create!(name: "Synthetic leaf", parent: original_root, color: Category::COLORS.first, lucide_icon: "circle")
    record = prepare
    assert_no_difference [ "Entry.count", "Category.count", "Tag.count" ] do
      record.icost_import.publish!(user: @user)
    end
    assert_equal "needs_review", record.reload.status
    assert_includes record.issues, "publication_validation_failed"
    assert_equal original_root.id, leaf.reload.parent_id
    assert_nil record.entry_id
    assert_equal [ "Synthetic root", "Synthetic leaf" ], record.category_path
  end

  test "deleting a native entry keeps its raw source for review and does not recreate money" do
    record = prepare
    record.icost_import.publish!(user: @user)
    raw = record.raw_fields
    record.reload.entry.destroy!
    record.reload
    assert_nil record.entry_id
    assert_equal raw, record.raw_fields
    assert_no_difference("Entry.count") { record.icost_import.publish!(user: @user) }
  end

  test "published source fields cannot be edited while review notes remain separately auditable" do
    record = prepare
    record.icost_import.publish!(user: @user)
    assert_raises(ActiveRecord::ReadonlyAttributeError) { record.update!(amount: BigDecimal("-999")) }
    assert_equal BigDecimal("-12.34"), record.reload.amount
    assert_equal "-12.3400", record.raw_fields["金额"]
  end

  private
    def prepare(overrides = {})
      row = Icost::Normalizer::HEADERS.index_with { "" }.merge(
        "日期" => "2024/01/02 13:14:15", "类型" => "支出", "金额" => "-12.3400",
        "一级分类" => "Synthetic root", "二级分类" => "Synthetic leaf", "账户1" => @account.name,
        "备注" => "Synthetic note", "货币" => "USD", "账本" => "Synthetic book"
      ).merge(overrides)
      bytes = CSV.generate { |csv| csv << row.keys; csv << row.values }
      IcostImport.prepare!(family: @family, user: @user, bytes: bytes, filename: "synthetic.csv").records.sole
    end
end
