require "test_helper"
require "csv"

class Icost::ReconcilerTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    Balance::Materializer.any_instance.stubs(:materialize_balances)
  end

  test "creates a source-named account and posts normal rows without opening valuations or sync" do
    batch = prepare(row, row("类型" => "收入", "金额" => "30"))
    Family.any_instance.expects(:sync_later).never
    Account.any_instance.expects(:sync_later).never
    assert_difference({ "Account.count" => 1, "Entry.count" => 2, "Valuation.count" => 0 }) do
      batch.process!(user: @user)
    end
    account = @family.accounts.find_by!(name: "Synthetic imported wallet", currency: "USD")
    assert_equal @user, account.owner
    assert_equal "Depository", account.accountable_type
    assert account.notes.present?
    assert_equal [ "published" ], batch.records.distinct.pluck(:status)
    assert_no_difference [ "Account.count", "Entry.count" ] do
      batch.process!(user: @user)
    end
  end

  test "invalid rows do not prevent normal rows from posting" do
    batch = prepare(row, row("金额" => "-0.00001"), row("类型" => "退款入账", "金额" => "4"))
    assert_difference("Entry.count", 1) { batch.process!(user: @user) }
    assert_equal [ "published", "needs_review", "needs_review" ], batch.records.order(:source_row).pluck(:status)
    assert_includes batch.records.find_by!(source_row: 3).issues, "amount_precision_unsupported"
    assert_includes batch.records.find_by!(source_row: 4).issues, "refund_link_required"
  end

  test "a row exceeding a database index limit does not roll back other rows" do
    large_category = Array.new(120) { SecureRandom.hex(32) }.join
    batch = prepare(row("一级分类" => large_category), row, row("金额" => "-7.5"))
    assert_difference("Entry.count", 2) { batch.process!(user: @user) }
    assert_equal "needs_review", batch.records.find_by!(source_row: 2).status
    assert_includes batch.records.find_by!(source_row: 2).issues, "publication_validation_failed"
  end

  test "new account balance reflects imported cashflow without fabricating an opening valuation" do
    Balance::Materializer.any_instance.unstub(:materialize_balances)
    batch = prepare(row, row("类型" => "收入", "金额" => "30"))
    assert_no_difference "Valuation.count" do
      batch.process!(user: @user)
    end
    account = batch.records.first.entry.account.reload
    assert_equal BigDecimal("17.66"), account.balance
    assert_equal BigDecimal("17.66"), account.cash_balance
    assert_equal BigDecimal("17.66"), account.balances.order(:date).last.end_balance
  end

  test "repairs missing published entries and then safely replays" do
    batch = prepare(row)
    batch.process!(user: @user)
    record = batch.records.sole
    original = record.attributes.slice("raw_fields", "row_sha256", "source_values")
    old_entry_id = record.entry_id
    record.entry.destroy!
    assert_equal "entry_missing", record.reload.display_status
    assert_difference("Entry.count", 1) { batch.process!(user: @user) }
    assert_equal "published", record.reload.display_status
    refute_equal old_entry_id, record.entry_id
    assert record.resolution["recovered_missing_entry"]
    assert_equal original, record.attributes.slice(*original.keys)
    assert_no_difference("Entry.count") { batch.process!(user: @user) }
    record.reload.entry.account.destroy!
    assert_difference({ "Account.count" => 1, "Entry.count" => 1 }) do
      batch.process!(user: @user)
    end
    assert_equal "published", record.reload.display_status
  end

  test "deduplicates overlapping exports while preserving identical occurrences within a file" do
    first = prepare(row, row)
    second = prepare(row("金额" => "-12.34"), row("金额" => "-12.34"), row("金额" => "-12.34"))
    assert_difference("Entry.count", 3) { second.process!(user: @user) }
    assert_equal 2, first.records.where(status: "published").count
    assert_equal 2, second.records.count { |record| record.display_status == "duplicate" }
    assert_equal 1, second.records.where(status: "published").count
    assert_no_difference [ "Entry.count", "Account.count" ] do
      first.process!(user: @user)
      second.process!(user: @user)
    end
  end

  test "relinks an existing source entry without duplicating it and preserves edited amounts" do
    batch = prepare(row)
    batch.process!(user: @user)
    record = batch.records.sole
    entry = record.entry
    record.update!(entry: nil)
    assert_no_difference("Entry.count") { batch.process!(user: @user) }
    assert_equal entry.id, record.reload.entry_id

    record.update!(entry: nil)
    entry.update!(amount: 99)
    assert_no_difference("Entry.count") { batch.process!(user: @user) }
    assert_equal 99, entry.reload.amount
    assert_equal "needs_review", record.reload.status
    assert_includes record.issues, "existing_entry_mismatch"
  end

  test "never selects another owners private account or changes account currency" do
    private_account = @family.accounts.create!(owner: users(:family_member), name: "Synthetic imported wallet",
      balance: 0, currency: "USD", accountable: OtherAsset.new)
    batch = prepare(row, row("货币" => "EUR"))
    assert_difference("Account.count", 2) { batch.process!(user: @user) }
    accounts = batch.records.map { |record| record.entry.account }
    assert_equal [ "EUR", "USD" ], accounts.map(&:currency).sort
    assert accounts.all? { |account| account.owner == @user && account.id != private_account.id }
  end

  test "rejects processing by another user or family" do
    batch = prepare(row)
    [ users(:family_member), users(:empty) ].each do |user|
      assert_raises(IcostImport::Error) { batch.process!(user: user) }
    end
    assert_nil batch.records.sole.entry_id
  end

  test "unrelated uploads do not resurrect deleted history but explicit recovery can" do
    old = prepare(row)
    old.process!(user: @user)
    old.records.sole.entry.destroy!
    recent = prepare(row("日期" => "2024/02/03 13:14:15"))
    assert_difference("Entry.count", 1) { recent.process!(user: @user) }
    assert_equal "entry_missing", old.records.sole.reload.display_status
    assert_difference("Entry.count", 1) { recent.process!(user: @user, recover_all: true) }
    assert_equal "published", old.records.sole.reload.display_status
  end

  test "a surviving transfer leg requires review instead of creating a second transfer" do
    batch = prepare(row("类型" => "转账", "金额" => "12.34", "账户1" => accounts(:depository).name, "账户2" => accounts(:other_asset).name))
    record = batch.records.sole
    record.resolve!(user: @user, attributes: { from_account_id: accounts(:depository).id, to_account_id: accounts(:other_asset).id })
    batch.publish!(user: @user)
    record.reload.counterpart_entry.destroy!
    assert_no_difference "Entry.count" do
      batch.process!(user: @user)
    end
    assert_equal "needs_review", record.reload.status
    assert_includes record.issues, "transfer_link_incomplete"
  end

  test "an existing source entry remains deduplicated after its archive is deleted" do
    first = prepare(row)
    first.process!(user: @user)
    entry_id = first.records.sole.entry_id
    first.records.sole.entry.account.update!(name: "Renamed imported wallet")
    first.destroy!
    later = prepare(row("金额" => "-12.34"))
    assert_no_difference [ "Entry.count", "Account.count" ] do
      later.process!(user: @user)
    end
    assert_equal entry_id, later.records.sole.entry_id
  end

  test "different ledgers remain distinct and ambiguous accounts do not block another source account" do
    2.times { @family.accounts.create!(owner: @user, name: "Ambiguous wallet", currency: "USD", balance: 0, accountable: OtherAsset.new) }
    batch = prepare(row("账户1" => "Ambiguous wallet"), row, row("账本" => "Another ledger"))
    assert_difference("Entry.count", 2) { batch.process!(user: @user) }
    assert_includes batch.records.find_by!(source_row: 2).issues, "account_ambiguous"
    assert_equal 2, @family.accounts.where(name: "Ambiguous wallet").count
  end

  private
    def row(overrides = {})
      Icost::Normalizer::HEADERS.index_with { "" }.merge(
        "日期" => "2024/01/02 13:14:15", "类型" => "支出", "金额" => "-12.3400",
        "一级分类" => "Synthetic expense", "账户1" => "Synthetic imported wallet", "货币" => "USD"
      ).merge(overrides)
    end

    def prepare(*rows)
      bytes = CSV.generate { |csv| csv << rows.first.keys; rows.each { |row| csv << row.values } }
      IcostImport.prepare!(family: @family, user: @user, bytes: bytes, filename: "synthetic-auto.csv")
    end
end
