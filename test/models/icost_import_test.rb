require "test_helper"
require "csv"
require "digest"

class IcostImportTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    Balance::Materializer.any_instance.stubs(:materialize_balances)
  end

  test "preserves all source fields unknown columns and exact original document" do
    row = source_row("备注" => "  Synthetic note\nsecond line  ", "位置" => "Synthetic place", "图片链接1" => "https://example.invalid/image", "未来字段" => "000123")
    bytes = csv_for(row)
    batch = prepare(bytes)
    record = batch.records.sole

    assert_equal bytes.b, batch.source_bytes.b
    assert_equal Digest::SHA256.hexdigest(bytes), batch.file_sha256
    assert_equal row.keys, batch.headers
    assert_equal row, record.raw_fields
    assert_equal row.values, record.source_values
    assert_equal({ "未来字段" => "000123" }, record.unknown_fields)
    assert_equal "2024/01/02 13:14:15", record.recorded_at_text
    assert_equal "Synthetic book", record.book_name
    assert_equal "Synthetic place", record.location_text
    assert_equal "https://example.invalid/image", record.image_references["图片链接1"]
    assert_equal "unknown", record.coordinate_system
    assert_nil record.latitude
    assert_nil record.longitude
    assert_equal BigDecimal("-12.3400"), record.amount
    assert_equal "ready", record.status
    assert_empty record.issues
    assert_empty @family.entries.where(idempotency_key: record.source_id)
  end

  test "repeated preparation and publishing never duplicate ledger entries" do
    bytes = csv_for(source_row)
    batch = prepare(bytes)
    assert_no_difference [ "IcostImport.count", "IcostRecord.count", "Entry.count" ] do
      assert_equal batch.id, prepare(bytes).id
    end

    assert_difference "Entry.count", 1 do
      batch.publish!(user: @user)
    end
    assert_no_difference [ "IcostImport.count", "IcostRecord.count", "Entry.count", "Transaction.count" ] do
      prepare(bytes).publish!(user: @user)
    end
    assert_equal "published", batch.records.sole.status
  end

  test "legacy provenance adopts a matching entry without modifying native data" do
    row = source_row("账户1" => "Synthetic legacy account", "标签" => "#Synthetic tag")
    bytes = csv_for(row)
    source_id = "icost:#{Digest::SHA256.hexdigest(bytes)}:CSV:2"
    row_hash = Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))
    @account.update!(name: "iCost预览｜Synthetic legacy account｜USD｜期初未知")
    root = category("Synthetic root")
    leaf = category("Synthetic leaf", root)
    tag = @family.tags.create!(name: "Synthetic tag")
    notes = "Original legacy note\r\n\r\n[iCost原始字段与来源]\r\n#{JSON.generate(source_id: source_id, row_sha256: row_hash)}"
    entry = @account.entries.create!(name: "Legacy title", date: "2024-01-02", amount: "12.34", currency: "USD", notes: notes,
      entryable: Transaction.new(kind: "standard", category: leaf, tags: [ tag ]))
    before_entry = entry.attributes
    before_transaction = entry.transaction.attributes

    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      batch = prepare(bytes)
      record = batch.records.sole
      assert_equal "published", record.status
      assert_equal entry.id, record.entry_id
      assert_equal source_id, record.source_id
      assert_equal row_hash, record.row_sha256
      batch.publish!(user: @user)
    end
    assert_equal before_entry, entry.reload.attributes
    assert_equal before_transaction, entry.transaction.reload.attributes
  end

  test "matching legacy source with changed native amount is quarantined rather than overwritten" do
    row = source_row
    bytes = csv_for(row)
    source_id = "icost:#{Digest::SHA256.hexdigest(bytes)}:CSV:2"
    row_hash = Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))
    entry = @account.entries.create!(name: "Edited transaction", date: "2024-01-02", amount: "99", currency: "USD",
      notes: "[iCost原始字段与来源]\n#{JSON.generate(source_id: source_id, row_sha256: row_hash)}",
      entryable: Transaction.new(kind: "standard"))
    before = entry.attributes

    assert_no_difference "Entry.count" do
      batch = prepare(bytes)
      record = batch.records.sole
      assert_equal "needs_review", record.status
      assert_includes record.issues, "existing_entry_mismatch"
      assert_nil record.entry_id
      batch.publish!(user: @user)
    end
    assert_equal before, entry.reload.attributes
  end

  test "a changed export containing an already published source row requires duplicate review" do
    row = source_row
    prepare(csv_for(row)).publish!(user: @user)
    bytes = csv_for(row, source_row("备注" => "Second synthetic row", "金额" => "-7.00"))
    batch = prepare(bytes)
    duplicate = batch.records.find_by!(source_row: 2)

    assert_equal "needs_review", duplicate.status
    assert_includes duplicate.issues, "possible_duplicate_source"
    assert_nil duplicate.entry_id
    assert_difference "Entry.count", 1 do
      batch.publish!(user: @user)
    end
  end

  test "identical legitimate rows within one source document remain separate transactions" do
    row = source_row
    batch = prepare(csv_for(row, row))
    records = batch.records.order(:source_row).to_a
    assert_equal [ 2, 3 ], records.map(&:source_row)
    assert_equal records.first.row_sha256, records.last.row_sha256
    refute_equal records.first.source_id, records.last.source_id

    assert_difference "Entry.count", 2 do
      batch.publish!(user: @user)
    end
    assert_equal [ "published", "published" ], batch.records.order(:source_row).pluck(:status)
    assert_equal 2, batch.records.pluck(:entry_id).uniq.size
    assert_no_difference("Entry.count") { batch.publish!(user: @user) }
  end

  test "two repackaged documents prepared before publishing cannot duplicate one source row" do
    bytes = csv_for(source_row)
    first = prepare(bytes)
    second = prepare(bytes.gsub("\n", "\r\n"))
    refute_equal first.file_sha256, second.file_sha256
    assert_equal first.records.sole.row_sha256, second.records.sole.row_sha256
    assert_equal "ready", first.records.sole.status
    assert_equal "ready", second.records.sole.status

    assert_difference "Entry.count", 1 do
      first.publish!(user: @user)
      second.publish!(user: @user)
    end
    assert_equal "published", first.records.sole.status
    assert_equal "needs_review", second.records.sole.status
    assert_includes second.records.sole.issues, "possible_duplicate_source"
    assert_nil second.records.sole.entry_id
  end

  test "duplicate protection is checked again after missing accounts are resolved" do
    bytes = csv_for(source_row("账户1" => ""))
    batches = [ prepare(bytes), prepare(bytes.gsub("\n", "\r\n")) ]
    batches.each do |batch|
      record = batch.records.sole
      assert_includes record.issues, "account_required"
      record.resolve!(user: @user, attributes: { account_id: @account.id })
      assert_equal "ready", record.reload.status
    end

    assert_difference "Entry.count", 1 do
      batches.each { |batch| batch.publish!(user: @user) }
    end
    assert_equal "published", batches.first.records.sole.status
    duplicate = batches.last.records.sole
    assert_equal "needs_review", duplicate.status
    assert_includes duplicate.issues, "possible_duplicate_source"
    assert_nil duplicate.entry_id
  end

  test "deleting an upload owner cleans up their pending archive without foreign key errors" do
    owner = users(:family_member)
    batch = IcostImport.prepare!(family: @family, user: owner, filename: "synthetic.csv",
      bytes: csv_for(source_row("账户1" => "")))
    source_record_id = batch.records.sole.id
    assert_equal "needs_review", batch.records.sole.status
    assert_nil batch.records.sole.entry_id

    assert_no_difference [ "Entry.count", "Account.count" ] do
      assert_difference({ "IcostImport.count" => -1, "IcostRecord.count" => -1, "User.count" => -1 }) do
        owner.destroy!
      end
    end
    refute IcostImport.exists?(batch.id)
    refute IcostRecord.exists?(source_record_id)
    assert User.exists?(@user.id)
  end

  test "preparation rejects guests cross-family users and another users existing source" do
    bytes = csv_for(source_row)
    assert_raises(IcostImport::Error) do
      IcostImport.prepare!(family: @family, user: users(:empty), bytes: bytes, filename: "synthetic.csv")
    end
    assert_raises(IcostImport::Error) do
      IcostImport.prepare!(family: users(:intro_user).family, user: users(:intro_user), bytes: bytes, filename: "synthetic.csv")
    end
    prepare(bytes)
    assert_no_difference [ "IcostImport.count", "IcostRecord.count" ] do
      assert_raises(IcostImport::Error) do
        IcostImport.prepare!(family: @family, user: users(:family_member), bytes: bytes, filename: "synthetic.csv")
      end
    end
  end

  test "publishing is restricted to the owner and family" do
    batch = prepare(csv_for(source_row))
    [ users(:family_member), users(:empty) ].each do |user|
      assert_no_difference "Entry.count" do
        assert_raises(IcostImport::Error) { batch.publish!(user: user) }
      end
    end
    assert_equal "ready", batch.records.sole.status
  end

  test "deleting provenance never deletes its existing ledger entries" do
    batch = prepare(csv_for(source_row))
    batch.publish!(user: @user)
    entry = batch.records.sole.entry
    assert_no_difference([ "Entry.count", "Transaction.count" ]) { batch.destroy! }
    assert Entry.exists?(entry.id)
  end

  private
    def source_row(overrides = {})
      Icost::Normalizer::HEADERS.index_with { "" }.merge(
        "日期" => "2024/01/02 13:14:15", "类型" => "支出", "金额" => "-12.3400",
        "一级分类" => "Synthetic root", "二级分类" => "Synthetic leaf", "账户1" => @account.name,
        "备注" => "Synthetic note", "货币" => "USD", "账本" => "Synthetic book"
      ).merge(overrides)
    end

    def csv_for(*rows)
      CSV.generate do |csv|
        csv << rows.first.keys
        rows.each { |row| csv << row.values }
      end
    end

    def prepare(bytes)
      IcostImport.prepare!(family: @family, user: @user, bytes: bytes, filename: "synthetic.csv")
    end

    def category(name, parent = nil)
      @family.categories.create!(name: name, parent: parent, color: Category::COLORS.first, lucide_icon: "circle")
    end
end
