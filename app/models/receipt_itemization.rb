# A private, review-only result. No split is saved by the AI job.
class ReceiptItemization < ApplicationRecord
  include Ai::Requester
  ai_feature :extract_receipt

  belongs_to :source_transaction, class_name: "Transaction", foreign_key: :transaction_id
  belongs_to :user
  belongs_to :attachment, class_name: "ActiveStorage::Attachment"
  validates :status, inclusion: { in: %w[pending completed failed] }
  validate :attachment_belongs_to_transaction

  def self.start!(transaction:, user:, attachment_id: nil)
    attachments = Transaction::ReceiptItemizer.receipt_attachments(transaction)
    attachment = attachment_id.present? ? attachments.find { _1.id.to_s == attachment_id.to_s } : attachments.first
    raise Transaction::ReceiptItemizer::Error, "No receipt attachment found" unless attachment
    raise Transaction::ReceiptItemizer::Error, "Transaction cannot be split" unless transaction.splittable?

    request = create!(source_transaction: transaction, user:, attachment:)
    begin
      queued = Ai::GenerationJob.perform_later(:extract_receipt, { id: request.id })
      raise ActiveJob::EnqueueError, "receipt job was not queued" unless queued
    rescue StandardError => error
      request.ai_failed(error)
    end
    request
  end

  def self.from_ai_job(id:, **) = find(id)

  def ai_correlation_id = "receipt:#{id}"

  def ai_generation
    return unless status == "pending"
    raise Ai::Error::Cancelled, "receipt is no longer accessible" if ai_cancelled?

    Ai::Generations::ExtractReceipt.new(attachment:, family: source_transaction.entry.account.family, user:)
  end

  def ai_cancelled?
    user.reload
    source_transaction.reload
    !user.family.accounts.accessible_by(user).where(id: source_transaction.entry.account_id).exists? ||
      !AccountPolicy.new(user, source_transaction.entry.account).update? ||
      !source_transaction.splittable? ||
      !Ai.available?(:extract_receipt, family: user.family, user:)
  end

  def apply_ai(result)
    raise Ai::Error::Cancelled, "receipt is no longer accessible" if ai_cancelled?

    extraction = Transaction::ReceiptExtraction::ReceiptExtraction.from_response(result.value!)
    value = Transaction::ReceiptItemizer.new(source_transaction).propose(attachment:, extraction:)
    with_lock do
      return 0 unless status == "pending"

      update!(status: "completed", proposal: {
        transaction_id: source_transaction.id, attachment_id: attachment.id, merchant_name: value.merchant_name,
        currency: source_transaction.entry.currency, receipt_total: value.receipt_total.to_s("F"),
        unmatched_amount: value.unmatched_amount.to_s("F"),
        split: { splits: value.rows.map { |row| { name: row.name, amount: row.amount.to_s("F") } } }
      })
    end
    1
  end

  def ai_finished(_count) = broadcast_result

  def ai_failed(error)
    with_lock { update!(status: "failed", error_code: error.class.name) if status == "pending" }
    DebugLogEntry.capture(category: "receipt_itemization", level: "warn", source: self.class.name,
      message: "Receipt itemization failed: #{error.class.name}", family: user.family,
      metadata: { receipt_itemization_id: id, transaction_id: transaction_id })
    broadcast_result
  end

  def editor_proposal
    return unless status == "completed"

    data = proposal.with_indifferent_access
    Transaction::ReceiptItemizer::Proposal.new(
      attachment_id: data[:attachment_id], merchant_name: data[:merchant_name],
      rows: data[:split][:splits].map { Transaction::ReceiptItemizer::Row.new(name: _1[:name], amount: BigDecimal(_1[:amount])) },
      receipt_total: BigDecimal(data[:receipt_total]), unmatched_amount: BigDecimal(data[:unmatched_amount])
    )
  end

  private
    def attachment_belongs_to_transaction
      errors.add(:attachment, "must belong to this transaction") unless attachment&.record == source_transaction
      errors.add(:user, "must belong to this family") unless user&.family_id == source_transaction&.entry&.account&.family_id
    end

    def broadcast_result
      Turbo::StreamsChannel.broadcast_action_to(self, action: :replace, target: "modal",
        partial: "splits/receipt_result", locals: { itemization: self })
    end
end
