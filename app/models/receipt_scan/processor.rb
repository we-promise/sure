# Turns a processing ReceiptScan into a finished transaction: reads the receipt with the routed
# AI model, checks the result, attaches it to the bank's version of the payment when that is
# already here, otherwise fills in the placeholder, and splits the spend by category.
class ReceiptScan::Processor
  # Problems that make the extracted payment unreliable enough not to merge into a bank entry.
  BLOCKING_PROBLEMS = %w[missing_total non_positive_total missing_date currency_mismatch unknown_currency].freeze

  def initialize(scan)
    @scan = scan
  end

  # Safe to run more than once: only a scan still processing is worked on. The AI call runs with
  # no database transaction open; the results are written under the scan's lock afterwards.
  # Any unexpected error ends the scan as failed rather than retrying a paid AI call.
  def process!
    scan.reload
    return unless scan.processing?

    @placeholder = scan.linked_transaction
    return record_failure(StandardError.new("The receipt's transaction was deleted")) unless placeholder

    unless Ai.availability(:extract_receipt, family:, user: scan.user).available? && provider
      return scan.with_lock do
        next unless scan.processing?

        scan.flag!(:ai_unavailable)
        write_receipt_extra(placeholder)
      end
    end

    @extraction = extract
    return unless extraction

    scan.with_lock do
      next unless scan.processing? && placeholder_still_there?

      apply_extraction
    end
  rescue StandardError => e
    record_failure(e)
  end

  # Ends a scan that won't be read as failed (e.g. its job couldn't be queued).
  def fail!(error)
    @placeholder = scan.linked_transaction
    record_failure(error)
  end

  private
    attr_reader :scan, :extraction, :problems, :placeholder

    def family = scan.family

    def placeholder_still_there?
      Transaction.exists?(placeholder.id) or raise StandardError, "The receipt's transaction was deleted"
    end

    def apply_extraction
      @problems = ReceiptScan::Validator.new(extraction, account: scan.account).problems
      problems.each { |problem| scan.flag!(problem["reason"], **problem.except("reason").symbolize_keys) }

      transaction = resolve_transaction
      fill(transaction) if transaction == placeholder
      categorize(transaction.entry)

      scan.update!(status: :completed) if scan.processing?
      write_receipt_extra(transaction)
    end

    def provider
      @provider ||= ReceiptScan.extraction_provider
    end

    def extract
      response = provider.extract_receipt(
        files: scan.files.map { |file| { data: file.download, content_type: file.content_type } },
        category_names: family.categories.pluck(:name),
        family:
      )
      return response.data if response.success?

      record_failure(response.error)
      nil
    end

    # Only a scan still processing fails: another run may have finished it meanwhile.
    def record_failure(error)
      failed = scan.with_lock do
        next false unless scan.processing?

        scan.update!(status: :failed, error: error&.message)
        write_receipt_extra(placeholder) if placeholder && Transaction.exists?(placeholder.id)
        true
      end
      return unless failed

      DebugLogEntry.capture(
        category: "ai",
        level: "error",
        message: "Receipt extraction failed: #{error&.message}",
        source: self.class.name,
        family:,
        account: scan.account,
        user: scan.user,
        metadata: { receipt_scan_id: scan.id, error_class: error&.class&.name }
      )
    end

    attr_reader :placeholder

    # The transaction this receipt ends up on: the bank's, when exactly one bank entry is this
    # payment, otherwise the placeholder.
    def resolve_transaction
      return placeholder if (problems.map { _1["reason"] } & BLOCKING_PROBLEMS).any?

      match = ReceiptScan::Matcher.new(scan, extraction).result
      case match.kind
      when :single
        merge_into(match.entries.first.entryable)
      when :ambiguous
        scan.flag!(:possible_duplicates, entry_ids: match.entries.map(&:id))
        placeholder
      when :duplicate_receipt
        scan.flag!(:duplicate_receipt, entry_id: match.entries.first.id)
        placeholder
      else
        placeholder
      end
    end

    # Holds the bank entry's lock until the scan's work commits, so two scans that both picked it
    # don't both merge: the second sees the first one's receipt and keeps its placeholder.
    def merge_into(bank_transaction)
      bank_entry = bank_transaction.entry
      bank_entry.lock!
      bank_transaction.lock!
      # The bank may have changed the entry since the matcher picked it (a pending booked at
      # another amount); then it is no longer this payment.
      unless bank_entry.amount == extraction.total && bank_entry.currency == extraction.currency && !bank_entry.excluded?
        return placeholder
      end

      if bank_transaction.extra["receipt"].present?
        scan.flag!(:duplicate_receipt, entry_id: bank_transaction.entry.id)
        return placeholder
      end

      if bank_transaction.attachments.count + scan.files.count > Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
        scan.flag!(:too_many_attachments, entry_id: bank_transaction.entry.id)
        return placeholder
      end

      bank_transaction.attachments.attach(scan.files.blobs)
      scan.update!(linked_transaction: bank_transaction)
      placeholder.attachments.detach
      placeholder.entry.destroy!
      bank_transaction
    end

    def fill(transaction)
      entry = transaction.entry
      entry.update!(
        name: extraction.merchant.presence || I18n.t("receipt_scans.fallback_name"),
        date: extraction.date || entry.date,
        amount: extraction.total || entry.amount,
        currency: known_currency?(extraction.currency) ? extraction.currency : entry.currency
      )
      entry.lock_saved_attributes!
      entry.sync_account_later
    end

    def known_currency?(code)
      code.present? && Money::Currency.new(code).present?
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    def categorize(entry)
      return if extraction.total.nil? || entry.amount != extraction.total
      return if entry.entryable.category_set_by_user?

      groups = ReceiptScan::CategoryAllocator.new(extraction, categories: family.categories).groups
      if groups.one?
        entry.entryable.update!(category: groups.first[:category]) if groups.first[:category]
      elsif groups.many? && entry.entryable.pending?
        # A pending transaction can't be split; the user splits it once the bank books it.
        scan.flag!(:split_after_booking)
      elsif groups.many?
        entry.split_once!(groups.map { |group| split_for(group) }, lock_attributes: true)
      end
    end

    def split_for(group)
      label = group[:category]&.name || I18n.t("receipt_scans.uncategorized_split_name")
      { name: [ extraction.merchant, label ].compact.join(" — "), amount: group[:amount], category_id: group[:category]&.id }
    end

    def write_receipt_extra(transaction)
      return unless transaction

      receipt = (transaction.extra["receipt"] || {}).merge(
        "scan_id" => scan.id,
        "status" => scan.completed? ? "completed" : (scan.processing? ? "processing" : "needs_review"),
        "review_reasons" => scan.review_reasons
      )
      receipt.merge!(extraction.to_h.as_json) if extraction
      transaction.update!(extra: transaction.extra.merge("receipt" => receipt))
    end
end
