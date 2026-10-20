# Proposes a split of a transaction from a receipt attached to it.
#
# The family's LLM provider reads the receipt's line items, tax and discount;
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

  # `amount` uses the parent entry's sign convention.
  Row = Data.define(:name, :amount)
  Proposal = Data.define(:attachment_id, :merchant_name, :rows, :receipt_total, :unmatched_amount)

  attr_reader :transaction

  # The receipt goes to the LLM provider, so this needs the user's AI consent
  # as well as a provider that can read it.
  def self.ai_ready?(user, provider: Provider::Registry.preferred_llm_provider)
    user&.ai_enabled? && provider.present? && provider.supports_receipt_extraction?
  end

  def self.available?(transaction, user:, provider: Provider::Registry.preferred_llm_provider)
    ai_ready?(user, provider: provider) &&
      transaction.splittable? &&
      readable_receipts(transaction, provider).any?
  end

  def self.receipt_attachments(transaction)
    transaction.attachments.select { |attachment| Transaction::ALLOWED_CONTENT_TYPES.include?(attachment.content_type) }
  end

  # Receipts the provider can read with its configured model: photos need a
  # vision-capable model, while PDFs can be read as text by any model.
  def self.readable_receipts(transaction, provider)
    receipt_attachments(transaction).select do |attachment|
      provider.supports_receipt_extraction?(content_type: attachment.content_type)
    end
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

  def initialize(transaction, provider: Provider::Registry.preferred_llm_provider)
    @transaction = transaction
    @provider = provider
  end

  # @param attachment_id [String, nil] a specific receipt; defaults to the
  #   first one the provider can read
  # @return [Proposal]
  def propose(attachment_id: nil)
    raise Error, "No LLM provider that can read receipts is configured" unless provider&.supports_receipt_extraction?
    raise Error, "Transaction cannot be split" unless transaction.splittable?

    attachment = nil
    begin
      attachment = find_attachment(attachment_id)
      response = provider.extract_receipt(
        file_content: attachment.download,
        content_type: attachment.content_type,
        family: entry.account.family
      )
      raise Error, "Could not read the receipt: #{response.error&.message}" unless response.success?

      build_proposal(attachment, response.data)
    rescue Error => e
      capture_failure(e, attachment, provider_error: response&.error)
      raise
    end
  end

  private
    attr_reader :provider

    def entry
      transaction.entry
    end

    def find_attachment(attachment_id)
      attachment =
        if attachment_id.present?
          self.class.receipt_attachments(transaction).find { |a| a.id.to_s == attachment_id.to_s }
        else
          self.class.readable_receipts(transaction, provider).first || self.class.receipt_attachments(transaction).first
        end
      raise Error, "No receipt attachment found" unless attachment

      unless provider.supports_receipt_extraction?(content_type: attachment.content_type)
        raise Error, "The configured model cannot read #{attachment.content_type} receipts; a vision-capable model is needed"
      end

      attachment
    end

    def build_proposal(attachment, extraction)
      ensure_same_currency!(extraction)

      items = extraction.line_items.reject { |item| item.amount.zero? }
      raise Error, "No line items found on the receipt" if items.empty?

      precision = Money::Currency.new(entry.currency).default_precision
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

    # Recoverable failures (the provider could not read the receipt, or what
    # it read cannot be turned into a split) go to the debug log so operators
    # can see them with family and provider context. Receipt content is not
    # logged.
    def capture_failure(error, attachment, provider_error: nil)
      DebugLogEntry.capture(
        category: "receipt_itemization",
        level: "warn",
        message: "Receipt itemization failed: #{error.message}",
        source: self.class.name,
        family: entry.account.family,
        account: entry.account,
        provider: provider,
        metadata: {
          transaction_id: transaction.id,
          attachment_id: attachment&.id,
          content_type: attachment&.content_type,
          provider_error_class: provider_error&.class&.name
        }.compact
      )
    end
end
