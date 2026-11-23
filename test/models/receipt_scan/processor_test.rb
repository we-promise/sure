require "test_helper"

class ReceiptScan::ProcessorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
    @food = categories(:food_and_drink)
    @household = @family.categories.create!(name: "Household", color: "#000000")
    @date = Date.current - 2.days
    use_ai_routes
  end

  test "creates placeholder and enqueues job" do
    scan = nil
    assert_enqueued_with(job: ReceiptScan::ProcessJob) do
      scan = upload("rotated.jpg", "image/jpeg")
    end

    entry = scan.linked_transaction.entry
    assert scan.processing?
    assert_equal I18n.t("receipt_scans.placeholder_name"), entry.name
    assert_equal 0, entry.amount
    assert_equal Date.current, entry.date
    assert_equal "processing", scan.linked_transaction.extra.dig("receipt", "status")
    assert_equal [ "image/jpeg" ], scan.files.map(&:content_type)
    assert_equal scan.files.map(&:blob_id), scan.linked_transaction.attachments.map(&:blob_id)
  end

  test "rejects six files" do
    files = Array.new(6) { uploaded("rotated.jpg", "image/jpeg") }

    assert_raises(ReceiptScan::InvalidUpload) do
      ReceiptScan.create_from_upload!(family: @family, user: @user, account: @account, uploads: files)
    end
  end

  test "a scan whose reading can't be queued is marked failed instead of processing forever" do
    ReceiptScan::ProcessJob.stubs(:perform_later).returns(false)

    scan = upload("rotated.jpg", "image/jpeg")

    assert scan.reload.failed?
    assert_equal "needs_review", scan.linked_transaction.extra.dig("receipt", "status")
  end

  test "a queueing error also marks the scan failed" do
    ReceiptScan::ProcessJob.stubs(:perform_later).raises(RedisClient::CannotConnectError)

    scan = upload("rotated.jpg", "image/jpeg")

    assert scan.reload.failed?
  end

  test "rejects a pdf sent with other files" do
    [ uploaded("receipt.pdf", "application/pdf"), uploaded("rotated.jpg", "image/jpeg") ].each do |other|
      assert_raises(ReceiptScan::InvalidUpload) do
        ReceiptScan.create_from_upload!(family: @family, user: @user, account: @account,
                                         uploads: [ uploaded("receipt.pdf", "application/pdf"), other ])
      end
    end
  end

  test "rejects an account moved to another family before the scan is saved" do
    stale = Account.find(@account.id)
    @account.update_columns(family_id: families(:empty).id)

    assert_raises(ActiveRecord::RecordInvalid) do
      ReceiptScan.create_from_upload!(family: @family, user: @user, account: stale, uploads: [ uploaded("rotated.jpg", "image/jpeg") ])
    end
  end

  test "a scan whose files can't be stored ends as failed instead of processing" do
    ActiveStorage::Attached::Changes::CreateMany.any_instance.stubs(:upload).raises(StandardError, "storage down")

    scan = nil
    assert_no_enqueued_jobs(only: ReceiptScan::ProcessJob) do
      scan = upload("rotated.jpg", "image/jpeg")
    end

    assert scan.reload.failed?
    assert_equal "storage down", scan.error
  end

  test "rejects an uploader who lost write access to the account" do
    member = users(:family_member)
    Account.stubs(:writable_by).with(member).returns(Account.none)

    assert_raises(ReceiptScan::InvalidUpload) do
      ReceiptScan.create_from_upload!(family: @family, user: member, account: @account, uploads: [ uploaded("rotated.jpg", "image/jpeg") ])
    end
  end

  test "rejects txt" do
    assert_raises(ReceiptScan::InvalidUpload) do
      ReceiptScan.create_from_upload!(family: @family, user: @user, account: @account,
                                       uploads: [ Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain") ])
    end
  end

  test "fills placeholder and splits by category" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "30.00", "Food & Drink"), item("Soap", "20.00", "Household") ])

    process(scan)

    entry = scan.reload.linked_transaction.entry
    assert scan.completed?
    assert_equal "Corner Grocer", entry.name
    assert_equal @date, entry.date
    assert_equal BigDecimal("50.00"), entry.amount
    assert entry.split_parent?
    assert_equal({ @food.id => BigDecimal("30.00"), @household.id => BigDecimal("20.00") },
                 entry.child_entries.to_h { [ _1.entryable.category_id, _1.amount ] })
    assert_equal "completed", entry.entryable.extra.dig("receipt", "status")
    assert_equal "Corner Grocer", entry.entryable.extra.dig("receipt", "merchant")
  end

  test "single category sets category without split" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])

    process(scan)

    entry = scan.reload.linked_transaction.entry
    assert_not entry.split_parent?
    assert_equal @food, entry.entryable.category
  end

  test "merges into existing bank transaction" do
    bank = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date + 1.day, currency: "USD",
                         amount: BigDecimal("50.00"), entryable: Transaction.new)
    scan = upload("rotated.jpg", "image/jpeg")
    placeholder_entry = scan.linked_transaction.entry
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])

    process(scan)

    assert_not Entry.exists?(placeholder_entry.id)
    assert_equal bank.entryable, scan.reload.linked_transaction
    assert_equal scan.files.map(&:blob_id), bank.entryable.attachments.map(&:blob_id)
    assert_equal "Corner Grocer", bank.entryable.reload.extra.dig("receipt", "merchant")
    assert_equal @food, bank.entryable.category
  end

  # Two scans can pick the same bank entry before either has merged: the second must
  # see the first one's receipt once it holds the entry's lock.
  test "a bank transaction another receipt merged into meanwhile isn't taken twice" do
    bank = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date + 1.day, currency: "USD",
                         amount: BigDecimal("50.00"), entryable: Transaction.new)
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])
    bank.entryable # the matcher hands over this instance, loaded before the other receipt lands
    ReceiptScan::Matcher.any_instance.stubs(:result).returns(ReceiptScan::Matcher::Result.new(kind: :single, entries: [ bank ]))
    Transaction.find(bank.entryable_id).update!(extra: { "receipt" => { "scan_id" => "other-scan", "merchant" => "First" } })

    process(scan)

    assert_equal "First", bank.entryable.reload.extra.dig("receipt", "merchant")
    assert_not_equal bank.entryable, scan.reload.linked_transaction
    assert_includes scan.review_reasons.map { _1["reason"] }, "duplicate_receipt"
  end

  test "a bank transaction whose amount changed after matching keeps the placeholder" do
    bank = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date + 1.day, currency: "USD",
                         amount: BigDecimal("50.00"), entryable: Transaction.new)
    scan = upload("rotated.jpg", "image/jpeg")
    placeholder = scan.linked_transaction
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])
    ReceiptScan::Matcher.any_instance.stubs(:result).returns(ReceiptScan::Matcher::Result.new(kind: :single, entries: [ bank ]))
    Entry.find(bank.id).update!(amount: BigDecimal("60.00"))

    process(scan)

    assert_equal placeholder, scan.reload.linked_transaction
    assert Entry.exists?(placeholder.entry.id)
    assert_nil bank.entryable.reload.extra["receipt"]
  end

  test "a run that fails after another run finished the scan leaves the finished scan alone" do
    scan = upload("rotated.jpg", "image/jpeg")
    provider = stub(supports_receipt_extraction?: true)
    provider.stubs(:extract_receipt).with do |**|
      # Another run completes the scan while this one waits for the model.
      ReceiptScan.find(scan.id).update!(status: :completed)
      true
    end.returns(Provider::Response.new(success?: false, data: nil, error: StandardError.new("timeout")))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    process(scan)

    assert scan.reload.completed?
    assert_nil scan.error
  end

  test "a category the user chose on the bank transaction is kept" do
    shopping = @family.categories.create!(name: "Shopping", color: "#000000")
    bank = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date + 1.day, currency: "USD",
                         amount: BigDecimal("50.00"), entryable: Transaction.new(category: shopping))
    bank.entryable.lock_attr!(:category_id)
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "30.00", "Food & Drink"), item("Soap", "20.00", "Household") ])

    process(scan)

    assert_equal bank.entryable, scan.reload.linked_transaction
    assert_equal shopping, bank.entryable.reload.category
    assert_not bank.reload.split_parent?
  end

  test "merges into a pending bank transaction and defers the split" do
    pending = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date, currency: "USD",
                            amount: BigDecimal("50.00"), entryable: Transaction.new(extra: { "plaid" => { "pending" => true } }))
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "30.00", "Food & Drink"), item("Soap", "20.00", "Household") ])

    assert_difference -> { Entry.count }, -1 do
      process(scan)
    end

    assert_equal pending.entryable, scan.reload.linked_transaction
    assert_not pending.reload.split_parent?
    assert_includes scan.review_reasons.map { _1["reason"] }, "split_after_booking"
  end

  test "ambiguous flags with entry ids" do
    ids = Array.new(2) do |i|
      Entry.create!(account: @account, name: "CARD", date: @date + i.days, currency: "USD",
                    amount: BigDecimal("50.00"), entryable: Transaction.new).id
    end
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction

    process(scan)

    reason = scan.reload.review_reasons.find { _1["reason"] == "possible_duplicates" }
    assert scan.needs_review?
    assert_equal ids.sort, reason["entry_ids"].sort
    assert_equal BigDecimal("50.00"), scan.linked_transaction.entry.amount
  end

  test "ai unavailable flags needs review" do
    use_no_ai
    scan = upload("rotated.jpg", "image/jpeg")

    process(scan)

    assert scan.reload.needs_review?
    assert_equal [ "ai_unavailable" ], scan.review_reasons.map { _1["reason"] }
    assert_equal "needs_review", scan.linked_transaction.extra.dig("receipt", "status")
  end

  test "provider error marks failed and logs" do
    scan = upload("rotated.jpg", "image/jpeg")
    provider = stub(supports_receipt_extraction?: true)
    provider.stubs(:extract_receipt).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("boom")))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    assert_difference -> { DebugLogEntry.count }, 1 do
      process(scan)
    end

    assert scan.reload.failed?
    assert_equal "needs_review", scan.linked_transaction.extra.dig("receipt", "status")
  end

  test "validation problems flag the scan but still fill the transaction" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "10.00", "Food & Drink") ])

    process(scan)

    assert scan.reload.needs_review?
    assert_includes scan.review_reasons.map { _1["reason"] }, "items_total_mismatch"
    assert_equal BigDecimal("50.00"), scan.linked_transaction.entry.amount
  end

  test "process is idempotent" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "30.00", "Food & Drink"), item("Soap", "20.00", "Household") ])

    process(scan)
    process(scan.reload)

    assert_equal 2, scan.linked_transaction.entry.child_entries.count
    assert scan.reload.completed?
  end

  test "calls the AI provider outside a database transaction" do
    scan = upload("rotated.jpg", "image/jpeg")
    baseline = ActiveRecord::Base.connection.open_transactions
    open_during_call = nil
    provider = stub(supports_receipt_extraction?: true)
    provider.stubs(:extract_receipt).with do |**|
      open_during_call = ActiveRecord::Base.connection.open_transactions
      true
    end.returns(Provider::Response.new(success?: true, data: build_receipt_extraction(date: @date), error: nil))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    process(scan)

    assert_equal baseline, open_during_call
  end

  test "a placeholder deleted before processing ends the scan as failed" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction
    scan.linked_transaction.entry.destroy!

    assert_nothing_raised { process(scan.reload) }

    assert scan.reload.failed?
  end

  test "an error after extraction marks the scan failed instead of raising" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])
    ReceiptScan::CategoryAllocator.any_instance.stubs(:groups).raises(StandardError, "boom")

    assert_difference -> { DebugLogEntry.count }, 1 do
      assert_nothing_raised { process(scan) }
    end

    assert scan.reload.failed?
    assert_equal "boom", scan.error
  end

  test "an error after the scan was flagged still marks it failed" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "10.00", "Food & Drink") ])
    ReceiptScan::Matcher.any_instance.stubs(:result).raises(StandardError, "boom")

    assert_nothing_raised { process(scan) }

    assert scan.reload.failed?
    assert_equal "boom", scan.error
    assert_empty scan.review_reasons
  end

  test "an error after merging into a bank transaction still marks the scan failed" do
    Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date, currency: "USD",
                  amount: BigDecimal("50.00"), entryable: Transaction.new)
    scan = upload("rotated.jpg", "image/jpeg")
    placeholder = scan.linked_transaction
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])
    ReceiptScan::CategoryAllocator.any_instance.stubs(:groups).raises(StandardError, "boom")

    assert_nothing_raised { process(scan) }

    assert scan.reload.failed?
    assert_equal placeholder, scan.linked_transaction
  end

  test "an unreadable currency keeps the account currency" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(currency: "ZL")

    process(scan)

    assert_equal "USD", scan.reload.linked_transaction.entry.currency
    assert_includes scan.review_reasons.map { _1["reason"] }, "unknown_currency"
  end

  private
    def uploaded(name, content_type)
      Rack::Test::UploadedFile.new(file_fixture("receipts/#{name}"), content_type)
    end

    def upload(name, content_type)
      ReceiptScan.create_from_upload!(family: @family, user: @user, account: @account, uploads: [ uploaded(name, content_type) ])
    end

    def item(name, amount, category_name)
      { "name" => name, "quantity" => "1", "amount" => amount, "discount" => "0", "category_name" => category_name }
    end

    def stub_extraction(**overrides)
      extraction = build_receipt_extraction(**{ date: @date, line_items: [] }.merge(overrides))
      provider = stub(supports_receipt_extraction?: true)
      provider.stubs(:extract_receipt).returns(Provider::Response.new(success?: true, data: extraction, error: nil))
      Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    end

    def process(scan)
      ReceiptScan::Processor.new(scan).process!
    end
end
