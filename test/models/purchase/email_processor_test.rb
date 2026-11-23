require "test_helper"

class Purchase::EmailProcessorTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include ActionMailer::TestHelper

  setup do
    @ordered_on = Date.current - 2.days
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_purchase))
    @purchase = create_email_purchase
  end

  test "an order matching one bank transaction is linked and the user is emailed" do
    entry = payment(date: @ordered_on + 1.day)
    stub_purchase_provider

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
      stub_purchase_provider(build_purchase_extraction(order_date: @ordered_on))

      process

      assert_equal entry.entryable, @purchase.reload.linked_transaction
    end
  end

  test "an order from several sellers becomes one purchase with sellers on its items" do
    stub_purchase_provider

    process

    assert_equal [ "HomeParts LLC", "Amazon.com" ], @purchase.reload.items.map(&:seller)
    assert_equal BigDecimal("249.99"), @purchase.total
  end

  test "the shop's domain is stored for its logo" do
    stub_purchase_provider

    process

    assert_equal "amazon.com", @purchase.reload.merchant_domain
  end

  # A forward whose block we can't recognize only shows the person who forwarded it.
  test "the forwarding user's own domain is not taken as the shop's" do
    purchase = Purchase.create!(family: @purchase.family, user: @purchase.user, source: :email, status: :processing)
    mail = Mail.new(from: "Bob Dylan <bob@bobdylan.com>", subject: "Fwd: my order", body: "Order total $249.99")
    purchase.original_email.attach(io: StringIO.new(mail.to_s), filename: "order.eml", content_type: "message/rfc822")
    stub_purchase_provider

    Purchase::EmailProcessor.new(purchase).process!

    purchase.reload
    assert_equal "awaiting_payment", purchase.status
    assert_nil purchase.merchant_domain
  end

  test "attachments go to the model with the text and only the receipt is kept" do
    attach_email_with_files
    provider = stub_purchase_provider(build_purchase_extraction(receipt_files: [ 1 ]))
    provider.expects(:extract_purchase).with { |**args| args[:files].map { _1[:filename] } == [ "receipt.jpg", "terms.pdf" ] }
            .returns(Provider::Response.new(success?: true, data: build_purchase_extraction(receipt_files: [ 1 ]), error: nil))

    process

    @purchase.reload
    assert_equal [ "receipt.jpg" ], @purchase.receipt_files.map { _1.filename.to_s }
    assert_equal [ [ "receipt.jpg", "image/jpeg", true ], [ "terms.pdf", "application/pdf", false ] ],
                 @purchase.ai_metadata["files"].map { [ _1["filename"], _1["content_type"], _1["receipt"] ] }
    assert @purchase.ai_metadata["files"].all? { _1["bytes"].positive? }
  end

  test "when the model rejects the attachments the order is still read from its text" do
    attach_email_with_files
    provider = stub_purchase_provider
    provider.expects(:extract_purchase).with { |**args| args[:files].any? }
            .returns(Provider::Response.new(success?: false, data: nil, error: Provider::Anthropic::Error.new("A maximum of 100 PDF pages may be provided")))
    provider.expects(:extract_purchase).with { |**args| args[:files].empty? }
            .returns(Provider::Response.new(success?: true, data: build_purchase_extraction, error: nil))

    process

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_empty @purchase.receipt_files
    assert @purchase.ai_metadata["files"].none? { _1["receipt"] }
    assert @purchase.ai_metadata["files_rejected"]
  end

  test "a purchase paid in cash isn't matched to a bank payment" do
    payment(date: @ordered_on)
    stub_purchase_provider(build_purchase_extraction(payment_method: "cash"))

    process
    Purchase::MatchPendingJob.perform_now

    @purchase.reload
    assert_equal "unmatched", @purchase.status
    assert_nil @purchase.linked_transaction
    assert_nil @purchase.match_deadline_on
  end

  test "a failed read that can't be queued again stays failed" do
    @purchase.update!(status: :failed, error: "timeout")
    Purchase::EmailProcessJob.stubs(:perform_later).raises(RedisClient::CannotConnectError)

    assert_raises(RedisClient::CannotConnectError) { @purchase.reprocess! }
    assert @purchase.reload.failed?
    assert_equal "timeout", @purchase.error
  end

  test "a notification that can't be sent doesn't fail a purchase that was read" do
    stub_purchase_provider
    ActionMailer::MessageDelivery.any_instance.stubs(:deliver_later).raises(RedisClient::CannotConnectError)

    process

    assert_equal "awaiting_payment", @purchase.reload.status
  end

  test "a user-excluded transaction isn't offered as the payment" do
    entry = payment(date: @ordered_on + 1.day)
    entry.update!(excluded: true)
    stub_purchase_provider

    process

    assert_nil @purchase.reload.linked_transaction
  end

  test "doesn't send the email to another provider when the preferred one can't read orders" do
    other = stub(supports_purchase_extraction?: true)
    other.expects(:extract_purchase).never
    Provider::Registry.stubs(:preferred_llm_provider).returns(stub(supports_purchase_extraction?: false))
    Provider::Registry.stubs(:get_provider).returns(other)

    process

    assert @purchase.reload.failed?
  end

  test "a run that fails after another run finished the purchase leaves it alone" do
    provider = stub(supports_purchase_extraction?: true, default_model: "claude-test")
    provider.stubs(:extract_purchase).with do |**|
      Purchase.find(@purchase.id).update!(status: :awaiting_payment)
      true
    end.returns(Provider::Response.new(success?: false, data: nil, error: StandardError.new("timeout")))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    process

    assert_equal "awaiting_payment", @purchase.reload.status
    assert_nil @purchase.error
  end

  test "no candidate leaves it awaiting payment with a deadline" do
    stub_purchase_provider

    process

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_equal @ordered_on + Purchase::DEADLINE_DAYS, @purchase.match_deadline_on
  end

  test "installments go straight to unmatched" do
    payment(date: @ordered_on)
    stub_purchase_provider(build_purchase_extraction(payment_method: "installments"))

    process

    assert_equal "unmatched", @purchase.reload.status
    assert_nil @purchase.transaction_id
  end

  test "not an order is rejected and the user told why" do
    stub_purchase_provider(build_purchase_extraction(is_order: false, not_order_reason: "Shipping notification"))

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
    stub_purchase_provider

    assert_enqueued_email_with PurchaseMailer, :rejected, params: { purchase: @purchase } do
      process
    end

    @purchase.reload
    assert_equal "rejected", @purchase.status
    assert_equal({ "reason" => "duplicate", "purchase_id" => existing.id }, @purchase.review_reasons.last)
  end

  test "validation problems are flagged and stored but the purchase is kept" do
    stub_purchase_provider(build_purchase_extraction(total: BigDecimal("300.00")))

    process

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_includes @purchase.review_reasons.map { _1["reason"] }, "items_mismatch"
    assert_equal [ "items_mismatch" ], @purchase.ai_metadata["validation"].map { _1["reason"] }
  end

  test "ai_metadata stores the raw output, model, prompt version and input size" do
    stub_purchase_provider

    process

    metadata = @purchase.reload.ai_metadata
    assert_equal "claude-test", metadata["model"]
    assert_equal Provider::Anthropic::PurchaseExtractor::PROMPT_VERSION, metadata["prompt_version"]
    assert_equal "Amazon.com", metadata.dig("raw_output", "merchant")
    assert_operator metadata["input_chars"], :>, 100
    assert_equal false, metadata["truncated"]
    assert metadata["extracted_at"].present?
  end

  test "a provider error fails the purchase, logs it and emails the user" do
    stub_purchase_provider(success: false, error: Provider::Error.new("boom"))

    assert_difference -> { DebugLogEntry.where(source: "Purchase::EmailProcessor").count }, 1 do
      assert_enqueued_email_with PurchaseMailer, :failed, params: { purchase: @purchase } do
        process
      end
    end

    @purchase.reload
    assert_equal "failed", @purchase.status
    assert_equal "boom", @purchase.error
  end

  test "an error while matching keeps what was read and waits for the payment" do
    stub_purchase_provider
    Purchase.any_instance.stubs(:apply_match!).raises(ActiveRecord::RecordNotUnique, "race")

    assert_enqueued_email_with PurchaseMailer, :processed, params: { purchase: @purchase } do
      process
    end

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_equal 2, @purchase.items.count
    assert DebugLogEntry.exists?(source: "Purchase::EmailProcessor", level: "warn")
  end

  test "AI unavailable fails without calling the provider" do
    Ai.stubs(:availability).returns(Ai::Availability.unavailable(:extract_purchase, :not_configured))
    provider = stub_purchase_provider
    provider.expects(:extract_purchase).never

    process

    assert_equal "failed", @purchase.reload.status
  end

  test "processing twice does nothing the second time" do
    provider = stub_purchase_provider
    process

    provider.expects(:extract_purchase).never
    process
  end

  test "reprocess! restarts a failed purchase" do
    @purchase.update!(status: :failed, error: "boom")

    assert_enqueued_with(job: Purchase::EmailProcessJob, args: [ @purchase ]) do
      @purchase.reprocess!
    end

    assert_equal "processing", @purchase.reload.status
    assert_nil @purchase.error
  end

  test "the job processes the purchase" do
    stub_purchase_provider

    Purchase::EmailProcessJob.perform_now(@purchase)

    assert_equal "awaiting_payment", @purchase.reload.status
  end

  private
    def process
      Purchase::EmailProcessor.new(@purchase).process!
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
