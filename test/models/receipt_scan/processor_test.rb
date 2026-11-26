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

  test "creates placeholder and queues the run that reads it" do
    scan = nil
    assert_enqueued_with(job: Ai::GenerationJob) do
      scan = upload("rotated.jpg", "image/jpeg")
    end
    assert_equal [ scan.id ], Ai::GenerationRun.find_by!(family: @family, feature: "extract_receipt").items.pluck(:item_id)

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

  test "a scan whose reading can't be queued waits in its run for delivery" do
    Ai::GenerationJob.stubs(:perform_later).raises(RedisClient::CannotConnectError)

    scan = upload("rotated.jpg", "image/jpeg")

    assert scan.reload.processing?
    assert Ai::GenerationRun.find_by!(family: @family, feature: "extract_receipt").next_job.present?
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

  test "files that can't be stored leave no scan, transaction or run behind" do
    ActiveStorage::Blob.stubs(:create_and_upload!).raises(StandardError, "storage down")

    assert_no_difference [ "ReceiptScan.count", "Entry.count", "Ai::GenerationRun.count" ] do
      assert_raises(StandardError) { upload("rotated.jpg", "image/jpeg") }
    end
  end

  test "an upload rejected under the locks purges the files it stored" do
    member = users(:family_member)
    Account.stubs(:writable_by).with(member).returns(Account.none)

    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(ReceiptScan::InvalidUpload) do
        ReceiptScan.create_from_upload!(family: @family, user: member, account: @account, uploads: [ uploaded("rotated.jpg", "image/jpeg") ])
      end
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    end
  end

  test "rejects a part that isn't a file" do
    [ "not a file", { "filename" => "x.jpg" } ].each do |part|
      assert_raises(ReceiptScan::InvalidUpload) do
        ReceiptScan.create_from_upload!(family: @family, user: @user, account: @account, uploads: [ part ])
      end
    end
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

  test "a total read with more decimals than the currency has is rounded to it" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(total: BigDecimal("10.005"), currency: "USD",
                    line_items: [ item("Cheese", "5.0025", "Food & Drink"), item("Soap", "5.0025", "Household") ])

    process(scan)

    entry = scan.reload.linked_transaction.entry
    assert_equal BigDecimal("10.01"), entry.amount
    assert_equal entry.amount, entry.child_entries.sum(:amount)
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

  test "what the user added to the placeholder moves to the bank transaction" do
    bank = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date + 1.day, currency: "USD", notes: "From the bank",
                         amount: BigDecimal("50.00"), entryable: Transaction.new(tags: [ tags(:one) ]))
    scan = upload("rotated.jpg", "image/jpeg")
    placeholder = scan.linked_transaction
    placeholder.update!(tags: [ tags(:two) ])
    placeholder.entry.update!(notes: "Team lunch")
    placeholder.attachments.attach(io: file_fixture("receipts/rotated.jpg").open, filename: "extra.jpg", content_type: "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])

    process(scan)

    transaction = bank.entryable.reload
    assert_equal transaction, scan.reload.linked_transaction
    assert_equal [ tags(:one), tags(:two) ].sort_by(&:id), transaction.tags.sort_by(&:id)
    assert_equal "From the bank\n\nTeam lunch", bank.reload.notes
    assert_includes transaction.attachments.map { _1.filename.to_s }, "extra.jpg"
    assert_equal 2, transaction.attachments.count
  end

  test "a split made from a receipt keeps the transaction's tags" do
    bank = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date + 1.day, currency: "USD",
                         amount: BigDecimal("50.00"), entryable: Transaction.new(tags: [ tags(:one) ]))
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "30.00", "Food & Drink"), item("Soap", "20.00", "Household") ])

    process(scan)

    assert bank.reload.split_parent?
    bank.child_entries.each { assert_equal [ tags(:one) ], _1.entryable.tags.to_a }
  end

  test "a placeholder the user edited while it was read isn't merged away" do
    bank = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date + 1.day, currency: "USD",
                         amount: BigDecimal("50.00"), entryable: Transaction.new)
    scan = upload("rotated.jpg", "image/jpeg")
    placeholder = scan.linked_transaction
    stub_ai(:extract_receipt) do
      placeholder.update!(category: @household)
      placeholder.lock_attr!(:category_id)
      receipt_ai_answer(date: @date.iso8601, line_items: [ item("Cheese", "50.00", "Food & Drink") ])
    end

    process(scan)

    assert_equal placeholder, scan.reload.linked_transaction
    assert_equal @household, placeholder.reload.category
    assert_nil bank.entryable.reload.extra["receipt"]
    assert_equal [ bank.id ], scan.review_reasons.find { _1["reason"] == "possible_duplicates" }["entry_ids"]
  end

  test "a scan moved to another family while it waited is still read" do
    scan = upload("rotated.jpg", "image/jpeg")
    requests = stub_extraction
    other = families(:empty)
    [ ReceiptScan.where(id: scan.id), Account.where(id: @account.id), User.where(id: @user.id) ].each { _1.update_all(family_id: other.id) }

    process(scan)

    assert_equal 1, requests.size
    assert_not scan.reload.processing?
  end

  test "a placeholder deleted while the receipt was read ends the run quietly" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_ai(:extract_receipt) do
      Entry.find(scan.linked_transaction.entry.id).destroy!
      receipt_ai_answer(date: @date.iso8601)
    end

    assert_no_difference -> { DebugLogEntry.where(source: "ReceiptScan::Processor").count } do
      assert_nothing_raised { process(scan) }
    end
    assert_not ReceiptScan.exists?(scan.id)
    assert_not Ai::GenerationRun.exists?(family: @family, feature: "extract_receipt")
  end

  test "files uploaded before a later one fails are deleted" do
    blob_count = ActiveStorage::Blob.count
    calls = 0
    original = ActiveStorage::Blob.method(:create_and_upload!)
    ActiveStorage::Blob.stubs(:create_and_upload!).with do |**args|
      calls += 1
      raise StandardError, "storage down" if calls == 2

      true
    end.returns(original.call(io: StringIO.new("x"), filename: "a.jpg", content_type: "image/jpeg"))

    assert_raises(StandardError) do
      ReceiptScan.create_from_upload!(family: @family, user: @user, account: @account,
                                       uploads: [ uploaded("rotated.jpg", "image/jpeg"), uploaded("rotated.jpg", "image/jpeg") ])
    end
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)

    assert_equal blob_count, ActiveStorage::Blob.count
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

  test "a bank transaction that became a transfer after matching keeps the placeholder" do
    bank = Entry.create!(account: @account, name: "CARD CORNER GROCER", date: @date + 1.day, currency: "USD",
                         amount: BigDecimal("50.00"), entryable: Transaction.new)
    scan = upload("rotated.jpg", "image/jpeg")
    placeholder = scan.linked_transaction
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])
    ReceiptScan::Matcher.any_instance.stubs(:result).returns(ReceiptScan::Matcher::Result.new(kind: :single, entries: [ bank ]))
    Transaction.find(bank.entryable_id).update!(kind: "funds_movement")

    process(scan)

    assert_equal placeholder, scan.reload.linked_transaction
    assert Entry.exists?(placeholder.entry.id)
    assert_nil bank.entryable.reload.extra["receipt"]
  end

  test "a scan whose uploader lost access to the account while it was read fails and leaves it alone" do
    scan = upload("rotated.jpg", "image/jpeg")
    placeholder = scan.linked_transaction
    stub_extraction(line_items: [ item("Cheese", "50.00", "Food & Drink") ])
    Account.stubs(:writable_by).with(@user).returns(Account.none)

    process(scan)

    assert scan.reload.failed?
    assert_equal placeholder, scan.linked_transaction
    assert_equal 0, placeholder.entry.reload.amount
    assert_equal "failed", placeholder.reload.extra.dig("receipt", "status")
  end

  test "a scan whose uploader was removed while it was read fails" do
    scan = upload("rotated.jpg", "image/jpeg")
    answer = receipt_ai_answer(date: @date.iso8601, line_items: [ item("Cheese", "50.00", "Food & Drink") ])
    stub_ai(:extract_receipt) do
      ReceiptScan.where(id: scan.id).update_all(user_id: nil)
      answer
    end

    process(scan)

    assert scan.reload.failed?
    assert_equal 0, scan.linked_transaction.entry.amount
  end

  test "a run that fails after another run finished the scan leaves the finished scan alone" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_ai(:extract_receipt) do
      # Another run completes the scan while this one waits for the model.
      ReceiptScan.find(scan.id).update!(status: :completed)
      raise Ai::Error::InvalidOutput, "not JSON"
    end

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

  test "an answer no route can use marks the scan failed, names its transaction and logs" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_ai(:extract_receipt, raises: Ai::Error::InvalidOutput.new("not JSON"))

    assert_difference -> { DebugLogEntry.where(source: "ReceiptScan::Processor").count }, 1 do
      process(scan)
    end

    assert scan.reload.failed?
    assert_equal "failed", scan.linked_transaction.extra.dig("receipt", "status")
    assert_equal I18n.t("receipt_scans.failed_name"), scan.linked_transaction.entry.name
  end

  test "a failed scan keeps a name the user gave its transaction" do
    scan = upload("rotated.jpg", "image/jpeg")
    entry = scan.linked_transaction.entry
    entry.update!(name: "Lunch")
    entry.lock_attr!(:name)
    stub_ai(:extract_receipt, raises: Ai::Error::InvalidOutput.new("not JSON"))

    process(scan)

    assert scan.reload.failed?
    assert_equal "Lunch", entry.reload.name
  end

  test "a model that times out leaves the scan processing for the job's retry" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_ai(:extract_receipt, raises: Ai::Error::Timeout.new("slow"))

    perform_enqueued_jobs(only: Ai::GenerationJob, at: Time.current)
    assert scan.reload.processing?
  end

  test "a busy local model leaves the scan processing" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_ai(:extract_receipt, raises: Ai::Error::Busy.new("busy"))

    perform_enqueued_jobs(only: Ai::GenerationJob, at: Time.current)
    assert scan.reload.processing?
  end

  test "sends a PDF as page images to a model that reads images" do
    scan = upload("receipt.pdf", "application/pdf")
    requests = stub_ai(:extract_receipt, returns: receipt_ai_answer(date: @date.iso8601))

    process(scan)

    assert scan.reload.completed? || scan.needs_review?
    assert requests.first.attachments.any?
    assert requests.first.attachments.all?(&:image?)
  end

  test "what the user changed on the placeholder while it was read is kept" do
    scan = upload("rotated.jpg", "image/jpeg")
    shopping = @family.categories.create!(name: "Shopping", color: "#000000")
    stub_ai(:extract_receipt) do
      entry = Entry.find(scan.linked_transaction.entry.id)
      entry.update!(name: "My lunch", amount: BigDecimal("42.00"))
      entry.lock_attr!(:name)
      entry.lock_attr!(:amount)
      transaction = entry.entryable
      transaction.update!(category: shopping, extra: transaction.extra.merge("exchange_rate" => "4.1"))
      transaction.lock_attr!(:category_id)
      receipt_ai_answer(date: @date.iso8601, line_items: [ item("Cheese", "30.00", "Food & Drink"), item("Soap", "20.00", "Household") ])
    end

    process(scan)

    entry = scan.reload.linked_transaction.entry
    assert_equal "My lunch", entry.name
    assert_equal BigDecimal("42.00"), entry.amount
    assert_equal @date, entry.date
    assert_equal shopping, entry.entryable.category
    assert_not entry.split_parent?
    assert_equal "4.1", entry.entryable.extra["exchange_rate"]
    assert_equal "Corner Grocer", entry.entryable.extra.dig("receipt", "merchant")
  end

  test "validation problems flag the scan but still fill the transaction" do
    scan = upload("rotated.jpg", "image/jpeg")
    stub_extraction(line_items: [ item("Cheese", "10.00", "Food & Drink") ])

    process(scan)

    assert scan.reload.needs_review?
    assert_includes scan.review_reasons.map { _1["reason"] }, "items_total_mismatch"
    assert_equal BigDecimal("50.00"), scan.linked_transaction.entry.amount
  end

  test "a second run over a finished scan changes nothing" do
    scan = upload("rotated.jpg", "image/jpeg")
    requests = stub_ai(:extract_receipt, returns: receipt_ai_answer(date: @date.iso8601, line_items: [ item("Cheese", "30.00", "Food & Drink"), item("Soap", "20.00", "Household") ]))

    process(scan)
    Ai::GenerationRun.enqueue(:extract_receipt, family: @family, ids: [ scan.id ])
    process(scan)

    assert_equal 1, requests.size

    assert_equal 2, scan.linked_transaction.entry.child_entries.count
    assert scan.reload.completed?
  end

  test "calls the AI model outside a database transaction" do
    scan = upload("rotated.jpg", "image/jpeg")
    baseline = ActiveRecord::Base.connection.open_transactions
    open_during_call = nil
    stub_ai(:extract_receipt) do
      open_during_call = ActiveRecord::Base.connection.open_transactions
      receipt_ai_answer(date: @date.iso8601)
    end

    process(scan)

    assert_equal baseline, open_during_call
  end

  test "a placeholder deleted before it was read takes its receipt with it, and the run ends quietly" do
    scan = upload("rotated.jpg", "image/jpeg")
    requests = stub_extraction
    scan.linked_transaction.entry.destroy!

    assert_nothing_raised { process(scan) }

    assert_not ReceiptScan.exists?(scan.id)
    assert_empty requests
    assert_not Ai::GenerationRun.exists?(family: @family, feature: "extract_receipt")
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
      { "name" => name, "quantity" => 1, "amount" => amount.to_f, "discount" => 0, "category_name" => category_name }
    end

    def stub_extraction(**overrides)
      overrides[:total] = overrides[:total].to_f if overrides[:total]
      stub_ai(:extract_receipt, returns: receipt_ai_answer(**{ date: @date.iso8601, line_items: [] }.merge(overrides)))
    end

    # Runs the scan's queued run, as the worker would.
    def process(_scan)
      perform_enqueued_jobs(only: Ai::GenerationJob)
    end
end
