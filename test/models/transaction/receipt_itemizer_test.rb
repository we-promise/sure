require "test_helper"

class Transaction::ReceiptItemizerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  Extraction = Transaction::ReceiptExtraction::ReceiptExtraction
  LineItem = Transaction::ReceiptExtraction::ReceiptLineItem

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
    provider = extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ], tax: 4)

    proposal = Transaction::ReceiptItemizer.new(@transaction).propose(attachment: @transaction.attachments.first, extraction: provider)

    assert_equal [ "Hammer", "Nails" ], proposal.rows.map(&:name)
    assert_equal [ BigDecimal("32.40"), BigDecimal("21.60") ], proposal.rows.map(&:amount)
    assert proposal.unmatched_amount.zero?

    @entry.split!(proposal.rows.map { |row| { name: row.name, amount: row.amount } })
    assert @entry.reload.split_parent?
  end

  test "puts what the receipt does not cover on a row named like the transaction" do
    provider = extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ])

    proposal = Transaction::ReceiptItemizer.new(@transaction).propose(attachment: @transaction.attachments.first, extraction: provider)

    assert_equal [ "Hammer", "Nails", "Hardware store" ], proposal.rows.map(&:name)
    assert_equal BigDecimal("4"), proposal.unmatched_amount
    assert_equal @entry.amount, proposal.rows.sum(&:amount)
  end

  test "keeps the sign of an inflow" do
    @entry.update!(amount: -50)
    provider = extraction(items: [ [ "Returned drill", 50 ] ])

    proposal = Transaction::ReceiptItemizer.new(@transaction.reload).propose(attachment: @transaction.reload.attachments.first, extraction: provider)

    assert_equal [ BigDecimal("-50") ], proposal.rows.map(&:amount)
  end

  test "rejects a receipt in another currency" do
    provider = extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ], currency: "eur")

    error = assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction).propose(attachment: @transaction.attachments.first, extraction: provider)
    end
    assert_match "EUR", error.message
    assert_match "USD", error.message
  end

  test "accepts a receipt without a currency or in the transaction's currency in any case" do
    [ nil, "usd" ].each do |currency|
      provider = extraction(items: [ [ "Hammer", 54 ] ], currency: currency)

      proposal = Transaction::ReceiptItemizer.new(@transaction).propose(attachment: @transaction.attachments.first, extraction: provider)

      assert_equal [ BigDecimal("54") ], proposal.rows.map(&:amount)
    end
  end

  test "does not add tax already included in the line prices" do
    provider = extraction(items: [ [ "Hammer", 34 ], [ "Nails", 20 ] ], tax: 9, total: 54)

    proposal = Transaction::ReceiptItemizer.new(@transaction).propose(attachment: @transaction.attachments.first, extraction: provider)

    assert_equal [ BigDecimal("34"), BigDecimal("20") ], proposal.rows.map(&:amount)
    assert proposal.unmatched_amount.zero?
  end

  test "adds tax when the total shows it was charged on top" do
    provider = extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ], tax: 4, total: 54)

    proposal = Transaction::ReceiptItemizer.new(@transaction).propose(attachment: @transaction.attachments.first, extraction: provider)

    assert_equal [ BigDecimal("32.40"), BigDecimal("21.60") ], proposal.rows.map(&:amount)
  end

  test "reads a refund receipt with negative lines by their magnitudes" do
    @entry.update!(amount: -54)
    provider = extraction(items: [ [ "Returned drill", -30 ], [ "Returned bits", -20 ] ], tax: -4, total: -54)

    proposal = Transaction::ReceiptItemizer.new(@transaction.reload).propose(attachment: @transaction.reload.attachments.first, extraction: provider)

    assert_equal [ BigDecimal("-32.40"), BigDecimal("-21.60") ], proposal.rows.map(&:amount)
    assert proposal.unmatched_amount.zero?
  end

  test "reads a refund receipt that prints its tax as a positive number" do
    @entry.update!(amount: -54)
    provider = extraction(items: [ [ "Returned drill", -30 ], [ "Returned bits", -20 ] ], tax: 4)

    proposal = Transaction::ReceiptItemizer.new(@transaction.reload).propose(attachment: @transaction.reload.attachments.first, extraction: provider)

    assert_equal [ BigDecimal("-32.40"), BigDecimal("-21.60") ], proposal.rows.map(&:amount)
  end

  test "raises when the receipt has no line items" do
    provider = extraction(items: [])

    assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction).propose(attachment: @transaction.attachments.first, extraction: provider)
    end
  end

  test "rejects an entry finer than the currency precision instead of dropping the residual" do
    @entry.update_columns(amount: BigDecimal("54.0049"))
    provider = extraction(items: [ [ "Hammer", 30 ], [ "Nails", 20 ] ])

    error = assert_raises(Transaction::ReceiptItemizer::Error) do
      Transaction::ReceiptItemizer.new(@transaction.reload).propose(attachment: @transaction.reload.attachments.first, extraction: provider)
    end
    assert_match(/more decimals/, error.message)
  end

  test "caps rows at the four decimals entries store for currencies with a finer precision" do
    entry = create_transaction(account: accounts(:depository), name: "Node hosting", currency: "BTC", amount: BigDecimal("0.5"))
    entry.transaction.attachments.attach(io: StringIO.new("%PDF-1.4 receipt"), filename: "receipt.pdf", content_type: "application/pdf")
    provider = extraction(items: [ [ "Hosting", "0.12345678" ], [ "Bandwidth", "0.2" ] ], currency: "BTC")

    proposal = Transaction::ReceiptItemizer.new(entry.transaction).propose(attachment: entry.transaction.attachments.first, extraction: provider)

    assert_equal 4, Transaction::ReceiptItemizer.amount_precision("BTC")
    assert_equal [ BigDecimal("0.1235"), BigDecimal("0.2"), BigDecimal("0.1765") ], proposal.rows.map(&:amount)

    entry.split!(proposal.rows.map { |row| { name: row.name, amount: row.amount } })
    assert_equal entry.amount, entry.reload.child_entries.sum(:amount)
    assert entry.child_entries.all? { |child| child.amount.nonzero? }
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
end
