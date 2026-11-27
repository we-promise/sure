# Proposes a split of a transaction from a receipt attached to it.
#
# A background generation reads the receipt's line items, tax and discount;
# this turns them into split rows that `Entry#split!` accepts: receipt-level
# tax and discounts are spread over the items in proportion to their amounts,
# each row is rounded to the currency's precision, and the rows always sum
# exactly to the transaction. When the receipt does not account for the whole
# transaction (a tip, a fee, a missed line), the difference becomes one more
# row under the transaction's own name, so nothing is silently rescaled.
#
# Receipts printed as refunds (negative lines) are read by their magnitudes,
# tax already included in the line prices (VAT-style receipts) is not added
# again, and a receipt in another currency than the transaction is rejected
# rather than mixed into the transaction's amounts.
#
# Nothing is saved here: the proposal is shown in the split editor (or
# returned by the API) for the user to review before splitting.
class Transaction::ReceiptItemizer
  Error = Class.new(StandardError)

  # entries.amount is decimal(19,4): crypto currencies with a finer default
  # precision (BTC, ETH: 8) are capped here so no row rounds away on save.
  STORED_AMOUNT_SCALE = 4

  # `amount` uses the parent entry's sign convention.
  Row = Data.define(:name, :amount)
  Proposal = Data.define(:attachment_id, :merchant_name, :rows, :receipt_total, :unmatched_amount)

  attr_reader :transaction

  def self.available?(transaction, user:)
    transaction.splittable? && receipt_attachments(transaction).any? &&
      Ai.available?(:extract_receipt, family: transaction.entry.account.family, user:)
  end

  # Decimals a split row can carry: the currency's precision, capped at what
  # entries.amount stores. The web editor uses it for its inputs too.
  def self.amount_precision(currency)
    [ Money::Currency.new(currency).default_precision, STORED_AMOUNT_SCALE ].min
  end

  def self.receipt_attachments(transaction)
    transaction.attachments.select { |attachment| Transaction::ALLOWED_CONTENT_TYPES.include?(attachment.content_type) }
  end

  # Spreads `tax - discount` over the items in proportion to their amounts
  # and rounds to `precision` decimals, putting the rounding residue on the
  # largest item. Returns the item amounts, positive for a purchase.
  def self.allocate(amounts, tax: nil, discount: nil, precision: 2)
    base = amounts.sum(BigDecimal("0"))
    raise Error, "Receipt line items do not add up to a positive amount" unless base.positive?

    adjustment = tax.to_d - discount.to_d
    target = (base + adjustment).round(precision)

    allocated = amounts.map { |amount| (amount + adjustment * amount / base).round(precision) }
    residue = target - allocated.sum(BigDecimal("0"))
    allocated[allocated.each_with_index.max_by { |amount, _| amount.abs }.last] += residue unless residue.zero?

    allocated
  end

  def initialize(transaction)
    @transaction = transaction
  end

  def propose(attachment:, extraction:)
    raise Error, "Transaction cannot be split" unless transaction.splittable?

    build_proposal(attachment, extraction)
  end

  private
    def entry = transaction.entry

    def build_proposal(attachment, extraction)
      ensure_same_currency!(extraction)

      items = extraction.line_items.reject { |item| item.amount.zero? }
      raise Error, "No line items found on the receipt" if items.empty?

      precision = self.class.amount_precision(entry.currency)
      sign = entry.amount.negative? ? -1 : 1
      parent_total = entry.amount.abs

      amounts, tax, total = receipt_magnitudes(items, extraction)
      tax = nil if tax_included_in_items?(amounts, tax: tax, discount: extraction.discount, total: total, precision: precision)

      allocated = self.class.allocate(amounts, tax: tax, discount: extraction.discount, precision: precision)
      rows = items.zip(allocated).map { |item, amount| Row.new(name: item.name, amount: amount * sign) }

      receipt_total = allocated.sum(BigDecimal("0"))
      # entries.amount is decimal(19,4): round to the currency's precision like
      # the item rows, so the leftover row never carries finer precision.
      unmatched = (parent_total - receipt_total).round(precision)
      # An entry finer than the currency precision (e.g. 54.0049 USD) can't be
      # split into precision-sized rows that sum to it exactly.
      if (parent_total - receipt_total - unmatched).nonzero?
        raise Error, "The transaction amount has more decimals than #{entry.currency} allows, so the receipt can't be split exactly"
      end
      rows << Row.new(name: entry.name, amount: unmatched * sign) unless unmatched.zero?

      Proposal.new(
        attachment_id: attachment.id,
        merchant_name: extraction.merchant_name,
        rows: rows,
        receipt_total: receipt_total,
        unmatched_amount: unmatched
      )
    end

    # A receipt's numbers are only meaningful in its own currency; converting
    # them would need the rate the card actually used, so the user splits a
    # foreign receipt by hand instead.
    def ensure_same_currency!(extraction)
      receipt_currency = extraction.currency.to_s.strip.upcase
      transaction_currency = entry.currency.to_s.upcase
      return if receipt_currency.blank? || receipt_currency == transaction_currency

      raise Error, "The receipt is in #{receipt_currency} but the transaction is in #{transaction_currency}"
    end

    # Refund receipts print their lines (and usually the tax and total) as
    # negative amounts. The split takes its sign from the transaction, so a
    # refund is read by its magnitudes.
    # @return [Array(Array<BigDecimal>, BigDecimal, BigDecimal)] item amounts, tax and total
    def receipt_magnitudes(items, extraction)
      amounts = items.map(&:amount)
      return [ amounts, extraction.tax, extraction.total ] unless amounts.sum(BigDecimal("0")).negative?

      [ amounts.map(&:-@), extraction.tax&.abs, extraction.total&.abs ]
    end

    # On tax-inclusive (VAT-style) receipts the printed line prices already
    # include the tax the receipt reports, so the lines alone reach the total.
    def tax_included_in_items?(amounts, tax:, discount:, total:, precision:)
      return false if tax.blank? || tax.zero? || total.blank?

      (amounts.sum(BigDecimal("0")) - discount.to_d).round(precision) == total.round(precision)
    end
end
