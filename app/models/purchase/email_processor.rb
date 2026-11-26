# Turns a forwarded order email into a purchase: reads it with the routed AI model, records the
# order and its items, rejects emails that aren't orders or repeat one already recorded, looks for
# the payment, and tells the user what happened.
#
# The requester of :extract_purchase. The mailbox and Purchase#reprocess! start a one-purchase
# Ai::GenerationRun; Ai::GenerationJob reads the email (ai_generation) with no database
# transaction open and applies the answer (apply_ai) under the purchase's lock. A failure that
# passes (an outage, a busy local model) is retried by the job; one that doesn't ends the
# purchase as failed (ai_failed).
class Purchase::EmailProcessor
  include Ai::Requester
  ai_feature :extract_purchase

  def self.from_ai_job(window:, family_id:)
    ids = window.take_matching { |ids| Purchase.where(id: ids, family_id:).pluck(:id) }
    new(Purchase.find_by(id: ids.first, family_id:))
  end

  # purchase: nil when it was deleted while the job waited.
  def initialize(purchase)
    @purchase = purchase
  end

  # The generation for a purchase still being read. Attachments go only to a model that reads
  # images; without one the email is read from its text.
  def ai_generation
    return unless purchase&.reload&.processing?

    mail = Mail.new(purchase.original_email.download)
    @email_text = Purchase::EmailText.new(mail).call
    @subject = mail.subject
    @files = email_text.files
    if files.any? && !self.class.reads_files?(family:, user: purchase.user)
      @files_rejected = true
      @files = []
    end

    Ai::Generations::ExtractPurchase.new(
      text: email_text.text, category_names: family.categories.pluck(:name), family:, user: purchase.user,
      files: files.map { Ai::Attachment.new(filename: _1[:filename], content_type: _1[:content_type], data: _1[:data]) }
    )
  end

  def apply_ai(result)
    return 0 unless purchase

    @extraction = Purchase::Extraction.from_ai(result.value, files: files.size)
    @route = result.route
    outcome = purchase.with_lock do
      next unless purchase.processing?

      apply_extraction
    end
    return 0 unless outcome

    match if outcome == :processed
    ActiveRecord.after_all_transactions_commit { notify(outcome) }
    1
  end

  def ai_failed(error)
    record_failure(error) if purchase
  end

  def ai_correlation_id = purchase && "purchase:#{purchase.id}"

  # Whether a model the member may use for order emails reads images.
  def self.reads_files?(family:, user:)
    plan = Ai.plan(:extract_purchase, family:, user:)
    plan.present? && plan.routes.any? { _1.model.capable?(:structured_output, :vision) }
  end

  private
    attr_reader :purchase, :extraction, :email_text, :subject, :files, :files_rejected

    def family = purchase.family

    # @return [Symbol] the email to send
    def apply_extraction
      problems = Purchase::Validator.new(extraction, family:).problems
      purchase.update!(ai_metadata: ai_metadata(problems))

      unless extraction.is_order
        purchase.update!(status: :rejected)
        purchase.flag!(:not_an_order)
        return :rejected
      end

      record_order(problems)
      if (existing = duplicate_of)
        purchase.update!(status: :rejected)
        purchase.flag!(:duplicate, purchase_id: existing.id)
        return :rejected
      end

      keep_receipt_files
      # A cash payment never shows up in a bank account: the user links or adds it by hand.
      if purchase.paid_by_cash?
        purchase.update!(status: :unmatched, match_deadline_on: nil)
      else
        purchase.update!(status: :awaiting_payment, match_deadline_on: extraction.order_date&.+(Purchase::DEADLINE_DAYS))
      end
      :processed
    end

    # In a savepoint after what was read is saved, so a failure here (e.g. two jobs linking the
    # same entry at once) only costs this attempt: the purchase waits and Purchase::MatchPendingJob
    # retries.
    def match
      Purchase.transaction(requires_new: true) do
        purchase.with_lock { purchase.apply_match! if purchase.awaiting_payment? }
      end
    rescue StandardError => e
      purchase.reload
      DebugLogEntry.capture(
        category: "purchase_inbox",
        level: "warn",
        message: "Matching a new purchase failed: #{e.message}",
        source: self.class.name,
        family:,
        user: purchase.user,
        metadata: { purchase_id: purchase.id, error_class: e.class.name }
      )
    end

    def record_order(problems)
      purchase.update!(
        merchant: extraction.merchant,
        order_number: extraction.order_number,
        ordered_on: extraction.order_date,
        total: extraction.total,
        currency: extraction.currency,
        shipping_cost: extraction.shipping_cost,
        payment_method: extraction.payment_method,
        merchant_domain: purchase.shop_domain(email_text.original_from_domain)
      )
      problems.each { |problem| purchase.flag!(problem["reason"], **problem.except("reason").symbolize_keys) }

      categories = family.categories.index_by { _1.name.downcase }
      purchase.items.delete_all
      Array(extraction.items).each_with_index do |item, position|
        purchase.items.create!(
          name: item["name"].presence || "?",
          quantity: decimal(item["quantity"]),
          unit_price: decimal(item["unit_price"]),
          amount: decimal(item["amount"]),
          category: categories[item["category_name"].to_s.downcase],
          seller: item["seller"].presence,
          position:
        )
      end
    end

    def keep_receipt_files
      purchase.receipt_files.purge
      receipt_file_numbers.each do |number|
        file = files[number - 1]
        purchase.receipt_files.attach(io: StringIO.new(file[:data]), filename: file[:filename], content_type: file[:content_type])
      end
    end

    def receipt_file_numbers
      Array(extraction.receipt_files)
    end

    # Another email purchase of this family for the same shop and order number. Checked under the
    # family's lock so two copies processed at once can't both pass.
    def duplicate_of
      return if purchase.order_number.blank?

      family.lock!
      family.purchases.email
        .where.not(id: purchase.id)
        .where.not(status: %w[rejected failed])
        .where("lower(merchant) = lower(?) AND lower(order_number) = lower(?)", purchase.merchant.to_s, purchase.order_number)
        .order(:created_at)
        .first
    end

    def ai_metadata(problems)
      {
        "endpoint" => @route&.model&.endpoint&.name,
        "model" => @route&.model&.name,
        "prompt" => @route&.prompt.presence || Ai::Generations::ExtractPurchase.prompt_key,
        "extracted_at" => Time.current.iso8601,
        "subject" => subject,
        "raw_output" => extraction.to_h.as_json,
        "validation" => problems,
        "input_chars" => email_text.input_chars,
        "truncated" => email_text.truncated,
        "files_rejected" => files_rejected.present?,
        "files" => files.each_with_index.map do |file, index|
          { "filename" => file[:filename], "content_type" => file[:content_type], "bytes" => file[:data].bytesize,
            "receipt" => receipt_file_numbers.include?(index + 1) }
        end
      }
    end

    # What was read is already saved: a notice that can't be queued is logged, not a failure.
    def notify(outcome)
      PurchaseMailer.with(purchase:).public_send(outcome).deliver_later
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "purchase_inbox",
        level: "warn",
        message: "Couldn't queue the #{outcome} email for a purchase: #{e.message}",
        source: self.class.name,
        family:,
        user: purchase.user,
        metadata: { purchase_id: purchase.id, error_class: e.class.name }
      )
    end

    # Only a purchase still being read fails: another run may have finished it meanwhile.
    def record_failure(error)
      failed = purchase.with_lock do
        next false unless purchase.processing?

        purchase.update!(status: :failed, error: error&.message)
        true
      end
      return unless failed

      DebugLogEntry.capture(
        category: "ai",
        level: "error",
        message: "Order email extraction failed: #{error&.message}",
        source: self.class.name,
        family:,
        user: purchase.user,
        metadata: { purchase_id: purchase.id, error_class: error&.class&.name }
      )
      ActiveRecord.after_all_transactions_commit { PurchaseMailer.with(purchase:).failed.deliver_later }
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
