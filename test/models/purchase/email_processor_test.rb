require "test_helper"

class Purchase::EmailProcessorTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include ActionMailer::TestHelper

  setup do
    @ordered_on = Date.current - 2.days
    use_ai_routes
    @purchase = create_email_purchase
  end

  test "an order matching one bank transaction is linked and the user is emailed" do
    entry = payment(date: @ordered_on + 1.day)
    stub_purchase_extraction

    assert_enqueued_email_with PurchaseMailer, :processed, params: { purchase: @purchase } do
      process
    end

    @purchase.reload
    assert_equal "matched", @purchase.status
    assert_equal entry.entryable, @purchase.linked_transaction
    assert_equal "Amazon.com", @purchase.merchant
    assert_equal "112-1234567-1234567", @purchase.order_number
    assert_equal BigDecimal("20.00"), @purchase.shipping_cost
    assert_equal [ "HEPA filter", "Travel mug" ], @purchase.items.map(&:name)
    assert_equal categories(:food_and_drink), @purchase.items.first.category
    assert_equal BigDecimal("79.98"), @purchase.items.first.amount
  end

  # The order date comes from the email, not from when it was forwarded.
  test "the window starts at the order date even when forwarded ten days later" do
    travel_to Date.current + 10.days do
      entry = payment(date: @ordered_on + 1.day)
      stub_purchase_extraction(build_purchase_extraction(order_date: @ordered_on))

      process

      assert_equal entry.entryable, @purchase.reload.linked_transaction
    end
  end

  test "an order from several sellers becomes one purchase with sellers on its items" do
    stub_purchase_extraction

    process

    assert_equal [ "HomeParts LLC", "Amazon.com" ], @purchase.reload.items.map(&:seller)
    assert_equal BigDecimal("249.99"), @purchase.total
  end

  test "the shop's domain is stored for its logo" do
    stub_purchase_extraction

    process

    assert_equal "amazon.com", @purchase.reload.merchant_domain
  end

  # A forward whose block we can't recognize only shows the person who forwarded it.
  test "the forwarding user's own domain is not taken as the shop's" do
    purchase = Purchase.create!(family: @purchase.family, user: @purchase.user, source: :email, status: :processing)
    mail = Mail.new(from: "Bob Dylan <bob@bobdylan.com>", subject: "Fwd: my order", body: "Order total $249.99")
    purchase.original_email.attach(io: StringIO.new(mail.to_s), filename: "order.eml", content_type: "message/rfc822")
    stub_purchase_extraction

    process(purchase)

    purchase.reload
    assert_equal "awaiting_payment", purchase.status
    assert_nil purchase.merchant_domain
  end

  test "attachments go to the model with the text and only the receipt is kept" do
    attach_email_with_files
    requests = stub_purchase_extraction(build_purchase_extraction(receipt_files: [ 1 ]))

    process

    assert_equal [ "file-1.jpg", "file-2-page-1.png" ], requests.first.attachments.map(&:filename)
    assert_includes requests.first.input, "1. receipt.jpg; 2. terms.pdf"

    @purchase.reload
    assert_equal [ "receipt.jpg" ], @purchase.receipt_files.map { _1.filename.to_s }
    assert_equal [ [ "receipt.jpg", "image/jpeg", true ], [ "terms.pdf", "application/pdf", false ] ],
                 @purchase.ai_metadata["files"].map { [ _1["filename"], _1["content_type"], _1["receipt"] ] }
    assert @purchase.ai_metadata["files"].all? { _1["bytes"].positive? }
  end

  test "with no model that reads images the order is read from its text" do
    use_ai_routes(extract_purchase: %w[gpu/qwen3-8b])
    attach_email_with_files
    requests = stub_purchase_extraction

    process

    assert_empty requests.first.attachments

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_empty @purchase.receipt_files
    assert @purchase.ai_metadata["files"].none? { _1["receipt"] }
    assert @purchase.ai_metadata["files_rejected"]
  end

  test "a purchase paid in cash isn't matched to a bank payment" do
    payment(date: @ordered_on)
    stub_purchase_extraction(build_purchase_extraction(payment_method: "cash"))

    process
    Purchase::MatchPendingJob.perform_now

    @purchase.reload
    assert_equal "unmatched", @purchase.status
    assert_nil @purchase.linked_transaction
    assert_nil @purchase.match_deadline_on
  end

  test "a failed read that can't be queued again stays failed" do
    @purchase.update!(status: :failed, error: "timeout")
    Ai::GenerationRun.stubs(:enqueue).raises(ActiveRecord::StatementInvalid, "db down")

    assert_raises(ActiveRecord::StatementInvalid) { @purchase.reprocess! }
    assert @purchase.reload.failed?
    assert_equal "timeout", @purchase.error
  end

  test "a notification that can't be sent doesn't fail a purchase that was read" do
    stub_purchase_extraction
    ActionMailer::MessageDelivery.any_instance.stubs(:deliver_later).raises(RedisClient::CannotConnectError)

    process

    assert_equal "awaiting_payment", @purchase.reload.status
  end

  test "a user-excluded transaction isn't offered as the payment" do
    entry = payment(date: @ordered_on + 1.day)
    entry.update!(excluded: true)
    stub_purchase_extraction

    process

    assert_nil @purchase.reload.linked_transaction
  end

  test "a run that fails after another run finished the purchase leaves it alone" do
    stub_ai(:extract_purchase) do
      Purchase.find(@purchase.id).update!(status: :awaiting_payment)
      raise Ai::Error::InvalidOutput, "not JSON"
    end

    process

    assert_equal "awaiting_payment", @purchase.reload.status
    assert_nil @purchase.error
  end

  test "a model that times out leaves the purchase processing for the job's retry" do
    stub_purchase_extraction(error: Ai::Error::Timeout.new("slow"))

    process

    assert @purchase.reload.processing?
  end

  test "no candidate leaves it awaiting payment with a deadline" do
    stub_purchase_extraction

    process

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_equal @ordered_on + Purchase::DEADLINE_DAYS, @purchase.match_deadline_on
  end

  test "installments go straight to unmatched" do
    payment(date: @ordered_on)
    stub_purchase_extraction(build_purchase_extraction(payment_method: "installments"))

    process

    assert_equal "unmatched", @purchase.reload.status
    assert_nil @purchase.transaction_id
  end

  test "not an order is rejected and the user told why" do
    stub_purchase_extraction(build_purchase_extraction(is_order: false, not_order_reason: "Shipping notification"))

    assert_enqueued_email_with PurchaseMailer, :rejected, params: { purchase: @purchase } do
      process
    end

    @purchase.reload
    assert_equal "rejected", @purchase.status
    assert_equal [ "not_an_order" ], @purchase.review_reasons.map { _1["reason"] }
    assert_equal "Fwd: Your Amazon.com order #112-1234567-1234567", @purchase.ai_metadata["subject"]
  end

  test "a second email for the same order number is rejected as a duplicate" do
    existing = Purchase.create!(family: @purchase.family, user: @purchase.user, source: :email, status: :awaiting_payment,
                                merchant: "AMAZON.COM", order_number: "112-1234567-1234567")
    stub_purchase_extraction

    assert_enqueued_email_with PurchaseMailer, :rejected, params: { purchase: @purchase } do
      process
    end

    @purchase.reload
    assert_equal "rejected", @purchase.status
    assert_equal({ "reason" => "duplicate", "purchase_id" => existing.id }, @purchase.review_reasons.last)
  end

  test "validation problems are flagged and stored but the purchase is kept" do
    stub_purchase_extraction(build_purchase_extraction(total: BigDecimal("300.00")))

    process

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_includes @purchase.review_reasons.map { _1["reason"] }, "items_mismatch"
    assert_equal [ "items_mismatch" ], @purchase.ai_metadata["validation"].map { _1["reason"] }
  end

  test "ai_metadata stores the raw output, model, prompt and input size" do
    stub_purchase_extraction

    process

    metadata = @purchase.reload.ai_metadata
    assert_equal "gpt-4.1-mini", metadata["model"]
    assert_equal "openai", metadata["endpoint"]
    assert_equal "extract_purchase", metadata["prompt"]
    assert_equal "Amazon.com", metadata.dig("raw_output", "merchant")
    assert_operator metadata["input_chars"], :>, 100
    assert_equal false, metadata["truncated"]
    assert metadata["extracted_at"].present?
  end

  test "a provider error fails the purchase, logs it and emails the user" do
    stub_purchase_extraction(error: Ai::Error::InvalidOutput.new("boom"))

    assert_difference -> { DebugLogEntry.where(source: "Purchase::EmailProcessor").count }, 1 do
      assert_enqueued_email_with PurchaseMailer, :failed, params: { purchase: @purchase } do
        process
      end
    end

    @purchase.reload
    assert_equal "failed", @purchase.status
    assert_match "boom", @purchase.error
  end

  test "an error while matching keeps what was read and waits for the payment" do
    stub_purchase_extraction
    Purchase.any_instance.stubs(:apply_match!).raises(ActiveRecord::RecordNotUnique, "race")

    assert_enqueued_email_with PurchaseMailer, :processed, params: { purchase: @purchase } do
      process
    end

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_equal 2, @purchase.items.count
    assert DebugLogEntry.exists?(source: "Purchase::EmailProcessor", level: "warn")
  end

  test "AI unavailable fails without calling a model" do
    use_no_ai
    requests = stub_purchase_extraction

    process

    assert_equal "failed", @purchase.reload.status
    assert_empty requests
  end

  test "a second run over a read purchase changes nothing" do
    requests = stub_purchase_extraction
    process
    process

    assert_equal 1, requests.size
  end

  test "reprocess! restarts a failed purchase once, however often it is clicked" do
    @purchase.update!(status: :failed, error: "boom")

    assert @purchase.reprocess!
    assert_not Purchase.find(@purchase.id).reprocess!

    assert_equal "processing", @purchase.reload.status
    assert_nil @purchase.error
    assert_equal 1, Ai::GenerationRun.where(family: @purchase.family, feature: "extract_purchase").count
  end

  test "a reprocessed purchase is read by its run" do
    @purchase.update!(status: :failed, error: "boom")
    stub_purchase_extraction

    @purchase.reprocess!
    perform_enqueued_jobs(only: Ai::GenerationJob, at: Time.current)

    assert_equal "awaiting_payment", @purchase.reload.status
  end

  private
    # Starts the purchase's run and performs it, as the mailbox and the worker would.
    def process(purchase = @purchase)
      Ai::GenerationRun.enqueue(:extract_purchase, family: purchase.family, ids: [ purchase.id ])
      perform_enqueued_jobs(only: Ai::GenerationJob, at: Time.current)
    end

    def attach_email_with_files
      mail = Mail.new(from: "Bob Dylan <bob@bobdylan.com>", subject: "Receipt", body: "My receipt")
      mail.add_file(filename: "receipt.png", content: Vips::Image.gaussnoise(300, 300).cast(:uchar).pngsave_buffer)
      mail.add_file(filename: "terms.pdf", content: build_pdf)
      @purchase.original_email.attach(io: StringIO.new(mail.to_s), filename: "order.eml", content_type: "message/rfc822")
    end

    def payment(date:, amount: BigDecimal("249.99"))
      create_transaction(account: accounts(:depository), date:, amount:, currency: "USD", name: "AMAZON MKTP")
    end
end
