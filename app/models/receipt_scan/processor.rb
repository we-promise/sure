# Turns a processing ReceiptScan into a finished transaction: reads the receipt with the routed
# AI model, checks the result, attaches it to the bank's version of the payment when that is
# already here, otherwise fills in the placeholder, and splits the spend by category.
#
# The requester of :extract_receipt. ReceiptScan.create_from_upload! starts a one-scan
# Ai::GenerationRun; Ai::GenerationJob reads the receipt (ai_generation) with no database
# transaction open and applies the answer (apply_ai) under the scan's locks. A failure that
# passes (an outage, a busy local model) is retried by the job; one that doesn't ends the scan
# (ai_failed).
class ReceiptScan::Processor
  include Ai::Requester
  ai_feature :extract_receipt

  # Problems that make the extracted payment unreliable enough not to merge into a bank entry.
  BLOCKING_PROBLEMS = %w[missing_total non_positive_total missing_date currency_mismatch unknown_currency].freeze

  # By id alone: a family transfer moves the scan while it waits, and it is read in its new
  # family rather than left processing. The run's ids are the scans its upload queued.
  def self.from_ai_job(window:, family_id:)
    ids = window.take_matching { |ids| ReceiptScan.where(id: ids).pluck(:id) }
    new(ReceiptScan.find_by(id: ids.first))
  end

  # scan: nil when it was deleted while the job waited.
  def initialize(scan)
    @scan = scan
  end

  # The generation for a scan still processing, or nil when there is nothing to read.
  def ai_generation
    return unless scan&.reload&.processing?

    unless (@placeholder = scan.linked_transaction)
      record_failure(StandardError.new("The receipt's transaction was deleted"))
      return
    end

    files = scan.files.map do |file|
      Ai::Attachment.new(filename: file.filename.to_s, content_type: file.content_type, data: file.download)
    end
    Ai::Generations::ExtractReceipt.new(files:, category_names: family.categories.pluck(:name), family:, user: scan.user)
  end

  def apply_ai(result)
    return 0 unless scan

    @extraction = ReceiptScan::Extraction.from_ai(result.value)
    # Amounts are kept to the currency's decimals, so the split parts can add up to the total.
    @extraction = extraction.with(total: extraction.total.round(precision)) if extraction.total

    outcome = with_completion_locks do
      next unless scan.processing?
      next :gone unless placeholder
      next :no_access unless uploader_can_write?

      apply_extraction
      :applied
    end
    case outcome
    when :gone then record_failure(StandardError.new("The receipt's transaction was deleted"))
    when :no_access then record_failure(StandardError.new("The uploader can no longer change this account"))
    end
    outcome == :applied ? 1 : 0
  rescue ActiveRecord::RecordNotFound
    0   # the scan, or its uploader or account, was deleted while the receipt was read
  end

  # No model the uploader may use can read images: the scan waits for review, with the
  # placeholder left for the user. Anything else ends it as failed.
  def ai_failed(error)
    # Read again: a failed apply may have left unsaved changes, and the scan may be gone.
    return unless scan && (@scan = ReceiptScan.find_by(id: scan.id))

    @placeholder = scan.linked_transaction
    return record_failure(error) unless error.is_a?(Ai::Error::Unavailable)

    scan.with_lock do
      next unless scan.processing?

      scan.flag!(:ai_unavailable)
      write_receipt_extra(locked_placeholder) if locked_placeholder
    end
  end

  def ai_correlation_id = scan && "receipt_scan:#{scan.id}"

  private
    attr_reader :scan, :extraction, :problems

    def family = scan.family

    # The uploader, then the account, then the scan: the order User#transfer_to_family! takes
    # them in, so a transfer and a scan finishing at the same time don't wait on each other. The
    # placeholder is locked and read again last: the user may have edited it while the receipt
    # was read.
    def with_completion_locks
      ReceiptScan.transaction do
        scan.user&.lock!
        scan.account.lock!
        scan.lock!
        @placeholder = locked_placeholder
        yield
      end
    end

    attr_reader :placeholder

    # The scan's transaction and its entry, locked and read again; nil when it was deleted.
    def locked_placeholder
      transaction = Transaction.lock.find_by(id: scan.transaction_id)
      return unless transaction&.entry

      transaction.entry.lock!
      transaction
    end

    # The upload's own rule, checked again: access can be lost while the receipt is read.
    def uploader_can_write?
      scan.user.present? && Account.writable_by(scan.user).exists?(scan.account_id)
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

    # Only a scan still processing fails: another run may have finished it meanwhile. The
    # placeholder keeps what the user gave it, and its name says the receipt wasn't read.
    def record_failure(error)
      failed = scan.with_lock do
        next false unless scan.processing?

        scan.update!(status: :failed, error: error&.message)
        if (transaction = locked_placeholder)
          entry = transaction.entry
          entry.update!(name: I18n.t("receipt_scans.failed_name")) unless entry.locked?(:name)
          write_receipt_extra(transaction)
        end
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
    # don't both merge: the second sees the first one's receipt and keeps its placeholder. What
    # the user added to the placeholder while the receipt was read (tags, notes, other files)
    # moves to the bank's transaction with the receipt.
    def merge_into(bank_transaction)
      bank_entry = bank_transaction.entry
      bank_entry.lock!
      bank_transaction.lock!
      # The bank may have changed the entry since the matcher picked it (a pending booked at
      # another amount, or one recognised as a transfer); then it is no longer this payment.
      unless bank_entry.amount == extraction.total && bank_entry.currency == extraction.currency && !bank_entry.excluded? &&
             Transaction::TRANSFER_KINDS.exclude?(bank_transaction.kind)
        return placeholder
      end

      if bank_transaction.extra["receipt"].present?
        scan.flag!(:duplicate_receipt, entry_id: bank_entry.id)
        return placeholder
      end

      # The user set something on the placeholder while the receipt was read: merging would drop
      # it. The user decides which one to keep.
      if placeholder.entry.locked_field_names.any?
        scan.flag!(:possible_duplicates, entry_ids: [ bank_entry.id ])
        return placeholder
      end

      blobs = placeholder.attachments.blobs.to_a
      if bank_transaction.attachments.count + blobs.size > Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
        scan.flag!(:too_many_attachments, entry_id: bank_entry.id)
        return placeholder
      end

      bank_transaction.attachments.attach(blobs)
      bank_transaction.update!(tag_ids: (bank_transaction.tag_ids + placeholder.tag_ids).uniq)
      notes = [ bank_entry.notes, placeholder.entry.notes ].compact_blank.uniq.join("\n\n")
      bank_entry.update!(notes:) if notes != bank_entry.notes.to_s
      scan.update!(linked_transaction: bank_transaction)
      placeholder.attachments.detach
      placeholder.entry.destroy!
      bank_transaction
    end

    # Fills in what the user hasn't set themselves while the receipt was read.
    def fill(transaction)
      entry = transaction.entry
      read = {
        name: extraction.merchant.presence || I18n.t("receipt_scans.fallback_name"),
        date: extraction.date,
        amount: extraction.total,
        currency: (extraction.currency if ReceiptScan.known_currency?(extraction.currency))
      }.compact.reject { |attribute, _| entry.locked?(attribute) }
      entry.update!(read)
      entry.lock_saved_attributes!
      entry.sync_account_later
    end

    def precision
      code = ReceiptScan.known_currency?(extraction.currency) ? extraction.currency : scan.account.currency
      Money::Currency.new(code).default_precision
    end

    def categorize(entry)
      return if extraction.total.nil? || entry.amount != extraction.total
      return if entry.entryable.category_set_by_user?

      groups = ReceiptScan::CategoryAllocator.new(extraction, categories: family.categories, precision:).groups
      if groups.one?
        entry.entryable.update!(category: groups.first[:category]) if groups.first[:category]
      elsif groups.many? && entry.entryable.pending?
        # A pending transaction can't be split; the user splits it once the bank books it.
        scan.flag!(:split_after_booking)
      elsif groups.many?
        tag_ids = entry.entryable.tag_ids
        entry.split_once!(groups.map { |group| split_for(group, tag_ids:) }, lock_attributes: true)
      end
    end

    def split_for(group, tag_ids:)
      label = group[:category]&.name || I18n.t("receipt_scans.uncategorized_split_name")
      { name: [ extraction.merchant, label ].compact.join(" — "), amount: group[:amount], category_id: group[:category]&.id, tag_ids: }
    end

    # Merged into the transaction's extra as it is now: the caller holds its lock.
    def write_receipt_extra(transaction)
      return unless transaction

      receipt = (transaction.extra["receipt"] || {}).merge(
        "scan_id" => scan.id,
        "status" => scan.status,
        "review_reasons" => scan.review_reasons
      )
      receipt.merge!(extraction.to_h.as_json) if extraction
      transaction.update!(extra: transaction.extra.merge("receipt" => receipt))
    end
end
