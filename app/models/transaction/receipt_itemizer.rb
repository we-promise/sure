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
      receipt_attachments(transaction).any?
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

  def initialize(transaction, provider: Provider::Registry.preferred_llm_provider)
    @transaction = transaction
    @provider = provider
  end

  # @param attachment_id [String, nil] a specific receipt; defaults to the first
  # @return [Proposal]
  def propose(attachment_id: nil)
    raise Error, "No LLM provider that can read receipts is configured" unless provider&.supports_receipt_extraction?
    raise Error, "Transaction cannot be split" unless transaction.splittable?

    attachment = find_attachment(attachment_id)
    response = provider.extract_receipt(
      file_content: attachment.download,
      content_type: attachment.content_type,
      family: entry.account.family
    )
    raise Error, "Could not read the receipt: #{response.error&.message}" unless response.success?

    build_proposal(attachment, response.data)
  end

  private
    attr_reader :provider

    def entry
      transaction.entry
    end

    def find_attachment(attachment_id)
      receipts = self.class.receipt_attachments(transaction)
      attachment = attachment_id.present? ? receipts.find { |a| a.id.to_s == attachment_id.to_s } : receipts.first
      raise Error, "No receipt attachment found" unless attachment

      attachment
    end

    def build_proposal(attachment, extraction)
      items = extraction.line_items.reject { |item| item.amount.zero? }
      raise Error, "No line items found on the receipt" if items.empty?

      precision = Money::Currency.new(entry.currency).default_precision
      sign = entry.amount.negative? ? -1 : 1
      parent_total = entry.amount.abs

      allocated = self.class.allocate(items.map(&:amount), tax: extraction.tax, discount: extraction.discount, precision: precision)
      rows = items.zip(allocated).map { |item, amount| Row.new(name: item.name, amount: amount * sign) }

      receipt_total = allocated.sum(BigDecimal("0"))
      unmatched = parent_total - receipt_total
      rows << Row.new(name: entry.name, amount: unmatched * sign) unless unmatched.zero?

      Proposal.new(
        attachment_id: attachment.id,
        merchant_name: extraction.merchant_name,
        rows: rows,
        receipt_total: receipt_total,
        unmatched_amount: unmatched
      )
    end
end
