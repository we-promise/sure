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
    provider.define_singleton_method(:supports_receipt_extraction?) { true }
    provider.define_singleton_method(:extract_receipt) do |**|
      Provider::Response.new(success?: false, data: nil, error: StandardError.new("provider down"))
    end

    error = assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction, provider: provider).propose
    end
    assert_match "provider down", error.message
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
    def extraction(items:, tax: nil, discount: nil)
      Extraction.new(
        merchant_name: "Hardware store",
        currency: "USD",
        line_items: items.map { |name, amount| LineItem.new(name: name, amount: BigDecimal(amount.to_s)) },
        tax: tax && BigDecimal(tax.to_s),
        discount: discount && BigDecimal(discount.to_s),
        total: nil
      )
    end

    def stub_provider(data, supports: true)
      provider = Object.new
      provider.define_singleton_method(:supports_receipt_extraction?) { supports }
      provider.define_singleton_method(:extract_receipt) do |**|
        Provider::Response.new(success?: true, data: data, error: nil)
      end
      provider
    end
end
