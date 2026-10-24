require "test_helper"

class Transaction::ReceiptItemizerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  Extraction = Provider::LlmConcept::ReceiptExtraction
  LineItem = Provider::LlmConcept::ReceiptLineItem

  setup do
    @user = users(:family_admin)
    @entry = create_transaction(account: accounts(:depository), name: "Hardware store", amount: 54.00)
    @transaction = @entry.transaction
    @transaction.attachments.attach(io: StringIO.new("%PDF-1.4 receipt"), filename: "receipt.pdf", content_type: "application/pdf")
  end

  test "allocate spreads tax over items in proportion and sums exactly" do
    allocated = Transaction::ReceiptItemizer.allocate([ BigDecimal("10"), BigDecimal("20"), BigDecimal("20") ], tax: BigDecimal("4"))

    assert_equal [ BigDecimal("10.80"), BigDecimal("21.60"), BigDecimal("21.60") ], allocated
    assert_equal BigDecimal("54"), allocated.sum
  end

  test "allocate subtracts a receipt-level discount" do
    allocated = Transaction::ReceiptItemizer.allocate([ BigDecimal("30"), BigDecimal("10") ], discount: BigDecimal("4"))

    assert_equal [ BigDecimal("27"), BigDecimal("9") ], allocated
  end

  test "allocate puts the rounding residue on the largest item" do
    allocated = Transaction::ReceiptItemizer.allocate(
      [ BigDecimal("1"), BigDecimal("1"), BigDecimal("1") ], tax: BigDecimal("0.10")
    )

    assert_equal [ BigDecimal("1.04"), BigDecimal("1.03"), BigDecimal("1.03") ], allocated
  end

  test "allocate rounds to the currency precision" do
    allocated = Transaction::ReceiptItemizer.allocate([ BigDecimal("100"), BigDecimal("200") ], tax: BigDecimal("31"), precision: 0)

    assert allocated.all? { |amount| amount == amount.round(0) }
    assert_equal BigDecimal("331"), allocated.sum
  end

  test "allocate rejects items that do not add up to a positive amount" do
    assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.allocate([ BigDecimal("5"), BigDecimal("-5") ])
    end
  end

  test "proposes rows that sum to the transaction and split cleanly" do
    provider = stub_provider(extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ], tax: 4))

    proposal = Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose

    assert_equal [ "Hammer", "Nails" ], proposal.rows.map(&:name)
    assert_equal [ BigDecimal("32.40"), BigDecimal("21.60") ], proposal.rows.map(&:amount)
    assert proposal.unmatched_amount.zero?

    @entry.split!(proposal.rows.map { |row| { name: row.name, amount: row.amount } })
    assert @entry.reload.split_parent?
  end

  test "puts what the receipt does not cover on a row named like the transaction" do
    provider = stub_provider(extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ]))

    proposal = Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose

    assert_equal [ "Hammer", "Nails", "Hardware store" ], proposal.rows.map(&:name)
    assert_equal BigDecimal("4"), proposal.unmatched_amount
    assert_equal @entry.amount, proposal.rows.sum(&:amount)
  end

  test "keeps the sign of an inflow" do
    @entry.update!(amount: -50)
    provider = stub_provider(extraction(items: [ [ "Returned drill", 50 ] ]))

    proposal = Transaction::ReceiptItemizer.new(@transaction.reload, provider: provider).propose

    assert_equal [ BigDecimal("-50") ], proposal.rows.map(&:amount)
  end

  test "raises when the provider cannot read receipts" do
    provider = stub_provider(nil, supports: false)

    assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
    end
  end

  test "raises when the provider fails" do
    provider = Object.new
    provider.define_singleton_method(:supports_receipt_extraction?) { |**| true }
    provider.define_singleton_method(:extract_receipt) do |**|
      Provider::Response.new(success?: false, data: nil, error: StandardError.new("provider down"))
    end

    error = assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
    end
    assert_match "provider down", error.message
  end

  test "records a provider failure in the debug log without receipt content" do
    provider = Object.new
    provider.define_singleton_method(:supports_receipt_extraction?) { |**| true }
    provider.define_singleton_method(:extract_receipt) do |**|
      Provider::Response.new(success?: false, data: nil, error: Provider::Openai::Error.new("provider down"))
    end

    assert_difference -> { DebugLogEntry.where(category: "receipt_itemization").count }, 1 do
      assert_raises(Transaction::ReceiptItemizer::Error) do
        Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
      end
    end

    log = DebugLogEntry.where(category: "receipt_itemization").recent.first
    assert_equal "warn", log.level
    assert_equal @entry.account.family, log.family
    assert_equal @entry.account, log.account
    assert_match "provider down", log.message
    assert_equal @transaction.id.to_s, log.metadata["transaction_id"].to_s
    assert_equal "application/pdf", log.metadata["content_type"]
    assert_equal "Provider::Openai::Error", log.metadata["provider_error_class"]
  end

  test "records an unusable extraction in the debug log" do
    provider = stub_provider(extraction(items: []))

    assert_difference -> { DebugLogEntry.where(category: "receipt_itemization").count }, 1 do
      assert_raises(Transaction::ReceiptItemizer::Error) do
        Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
      end
    end
  end

  test "rejects a receipt in another currency" do
    provider = stub_provider(extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ], currency: "eur"))

    error = assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
    end
    assert_match "EUR", error.message
    assert_match "USD", error.message
  end

  test "accepts a receipt without a currency or in the transaction's currency in any case" do
    [ nil, "usd" ].each do |currency|
      provider = stub_provider(extraction(items: [ [ "Hammer", 54 ] ], currency: currency))

      proposal = Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose

      assert_equal [ BigDecimal("54") ], proposal.rows.map(&:amount)
    end
  end

  test "does not add tax already included in the line prices" do
    provider = stub_provider(extraction(items: [ [ "Hammer", 34 ], [ "Nails", 20 ] ], tax: 9, total: 54))

    proposal = Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose

    assert_equal [ BigDecimal("34"), BigDecimal("20") ], proposal.rows.map(&:amount)
    assert proposal.unmatched_amount.zero?
  end

  test "adds tax when the total shows it was charged on top" do
    provider = stub_provider(extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ], tax: 4, total: 54))

    proposal = Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose

    assert_equal [ BigDecimal("32.40"), BigDecimal("21.60") ], proposal.rows.map(&:amount)
  end

  test "reads a refund receipt with negative lines by their magnitudes" do
    @entry.update!(amount: -54)
    provider = stub_provider(extraction(items: [ [ "Returned drill", -30 ], [ "Returned bits", -20 ] ], tax: -4, total: -54))

    proposal = Transaction::ReceiptItemizer.new(@transaction.reload, provider: provider).propose

    assert_equal [ BigDecimal("-32.40"), BigDecimal("-21.60") ], proposal.rows.map(&:amount)
    assert proposal.unmatched_amount.zero?
  end

  test "reads a refund receipt that prints its tax as a positive number" do
    @entry.update!(amount: -54)
    provider = stub_provider(extraction(items: [ [ "Returned drill", -30 ], [ "Returned bits", -20 ] ], tax: 4))

    proposal = Transaction::ReceiptItemizer.new(@transaction.reload, provider: provider).propose

    assert_equal [ BigDecimal("-32.40"), BigDecimal("-21.60") ], proposal.rows.map(&:amount)
  end

  test "reads a photo only when the provider can read images" do
    @transaction.attachments.purge
    @transaction.attachments.attach(io: StringIO.new("png"), filename: "receipt.png", content_type: "image/png")
    @transaction.reload
    text_only = stub_provider(extraction(items: [ [ "Hammer", 54 ] ]), image_support: false)

    assert_not Transaction::ReceiptItemizer.available?(@transaction, user: @user, provider: text_only)
    error = assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction, provider: text_only).propose
    end
    assert_match "vision-capable", error.message
  end

  test "offers PDFs to a provider that cannot read images" do
    text_only = stub_provider(extraction(items: [ [ "Hammer", 54 ] ]), image_support: false)

    assert Transaction::ReceiptItemizer.available?(@transaction, user: @user, provider: text_only)
    assert_equal [ BigDecimal("54") ], Transaction::ReceiptItemizer.new(@transaction, provider: text_only).propose.rows.map(&:amount)
  end

  test "raises when the receipt has no line items" do
    provider = stub_provider(extraction(items: []))

    assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
    end
  end

  test "raises when the transaction has no receipt" do
    @transaction.attachments.purge
    provider = stub_provider(extraction(items: [ [ "Hammer", 54 ] ]))

    assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction.reload, provider: provider).propose
    end
  end

  test "records a missing receipt in the debug log" do
    @transaction.attachments.purge
    provider = stub_provider(extraction(items: [ [ "Hammer", 54 ] ]))

    assert_difference -> { DebugLogEntry.where(category: "receipt_itemization").count }, 1 do
      assert_raises(Transaction::ReceiptItemizer::Error) do
        Transaction::ReceiptItemizer.new(@transaction.reload, provider: provider).propose
      end
    end

    log = DebugLogEntry.where(category: "receipt_itemization").recent.first
    assert_match "No receipt attachment found", log.message
  end

  test "rejects an entry finer than the currency precision instead of dropping the residual" do
    @entry.update_columns(amount: BigDecimal("54.0049"))
    provider = stub_provider(extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ]))

    error = assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction.reload, provider: provider).propose
    end
    assert_match(/more decimals/, error.message)
  end

  test "caps rows at the four decimals entries store for currencies with a finer precision" do
    entry = create_transaction(account: accounts(:depository), name: "Node hosting", currency: "BTC", amount: BigDecimal("0.5"))
    entry.transaction.attachments.attach(io: StringIO.new("%PDF-1.4 receipt"), filename: "receipt.pdf", content_type: "application/pdf")
    provider = stub_provider(extraction(items: [ [ "Hosting", "0.12345678" ], [ "Bandwidth", "0.2" ] ], currency: "BTC"))

    proposal = Transaction::ReceiptItemizer.new(entry.transaction, provider: provider).propose

    assert_equal 4, Transaction::ReceiptItemizer.amount_precision("BTC")
    assert_equal [ BigDecimal("0.1235"), BigDecimal("0.2"), BigDecimal("0.1765") ], proposal.rows.map(&:amount)

    entry.split!(proposal.rows.map { |row| { name: row.name, amount: row.amount } })
    assert_equal entry.amount, entry.reload.child_entries.sum(:amount)
    assert entry.child_entries.all? { |child| child.amount.nonzero? }
  end

  test "turns an unexpected error into an itemizer error and records it without its message" do
    provider = stub_provider(extraction(items: [ [ "Hammer", 54 ] ]))
    ActiveStorage::Attachment.any_instance.stubs(:download).raises(ActiveStorage::FileNotFoundError, "secret receipt line")

    error = nil
    assert_difference -> { DebugLogEntry.where(category: "receipt_itemization").count }, 1 do
      error = assert_raises(Transaction::ReceiptItemizer::Error) do
        Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
      end
    end

    assert_instance_of Transaction::ReceiptItemizer::Unavailable, error
    assert_match "ActiveStorage::FileNotFoundError", error.message
    assert_instance_of ActiveStorage::FileNotFoundError, error.cause
    log = DebugLogEntry.where(category: "receipt_itemization").recent.first
    assert_equal "error", log.level
    assert_equal "ActiveStorage::FileNotFoundError", log.metadata["error_class"]
    assert_no_match "secret receipt line", log.message
  end

  test "an unexpected non-infrastructure error is a plain itemizer error, not unavailable" do
    provider = stub_provider(extraction(items: [ [ "Hammer", 54 ] ]))
    ActiveStorage::Attachment.any_instance.stubs(:download).raises(ArgumentError, "bad")

    error = assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
    end

    assert_not_kind_of Transaction::ReceiptItemizer::Unavailable, error
  end

  test "available needs AI consent, a capable provider, a receipt and a splittable transaction" do
    provider = stub_provider(nil)

    assert Transaction::ReceiptItemizer.available?(@transaction, user: @user, provider: provider)

    @user.ai_enabled = false
    assert_not Transaction::ReceiptItemizer.available?(@transaction, user: @user, provider: provider)
    @user.ai_enabled = true

    assert_not Transaction::ReceiptItemizer.available?(@transaction, user: @user, provider: stub_provider(nil, supports: false))
    assert_not Transaction::ReceiptItemizer.available?(@transaction, user: @user, provider: nil)
  end

  private
    def extraction(items:, tax: nil, discount: nil, total: nil, currency: "USD")
      Extraction.new(
        merchant_name: "Hardware store",
        currency: currency&.upcase,
        line_items: items.map { |name, amount| LineItem.new(name: name, amount: BigDecimal(amount.to_s)) },
        tax: tax && BigDecimal(tax.to_s),
        discount: discount && BigDecimal(discount.to_s),
        total: total && BigDecimal(total.to_s)
      )
    end

    # `image_support: false` mimics a text-only model: PDFs are read as text,
    # photos are not.
    def stub_provider(data, supports: true, image_support: true)
      provider = Object.new
      provider.define_singleton_method(:supports_receipt_extraction?) do |content_type: nil, **|
        supports && (image_support || !content_type.to_s.start_with?("image/"))
      end
      provider.define_singleton_method(:extract_receipt) do |**|
        Provider::Response.new(success?: true, data: data, error: nil)
      end
      provider
    end
end
