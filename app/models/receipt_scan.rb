# A receipt, bill or invoice a family member photographed or uploaded, and the state of turning
# it into a transaction on the account they picked.
class ReceiptScan < ApplicationRecord
  MAX_FILES = 5
  MAX_FILE_SIZE = 10.megabytes
  ACCEPTED_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif application/pdf].freeze
  # Days either side of the receipt date in which a bank transaction counts as the same payment.
  MATCH_DATE_WINDOW = 3

  belongs_to :family
  belongs_to :account
  # Who uploaded it; nil once that member is removed.
  belongs_to :user, optional: true
  # Not `:transaction`: that name would shadow ActiveRecord::Base#transaction.
  belongs_to :linked_transaction, class_name: "Transaction", foreign_key: :transaction_id, optional: true

  # The same files are the transaction's attachments. A blob is deleted once neither holds it:
  # see purge_unshared_files.
  has_many_attached :files, dependent: false

  before_destroy :release_files
  after_destroy_commit :purge_unshared_files

  enum :status, {
    processing: "processing",
    completed: "completed",
    needs_review: "needs_review",
    failed: "failed"
  }, validate: true

  validate :account_belongs_to_family

  InvalidUpload = Class.new(StandardError)

  class << self
    # Whether receipts can be read for this family and user: the uploader allows AI, and a route
    # for receipts has a model that reads images.
    def extraction_available?(family:, user:)
      plan = Ai.plan(:extract_receipt, family:, user:)
      plan.present? && plan.routes.any? { _1.model.capable?(:structured_output, :vision) }
    end

    def known_currency?(code)
      code.present? && Money::Currency.new(code).present?
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    # Stores the normalized files and gives the user a "Processing receipt…" transaction on the
    # account right away, with the run that reads it (ReceiptScan::Processor) queued once it
    # commits. The files are uploaded first, so the run never reads a scan without its files. The
    # caller authorizes the account.
    def create_from_upload!(family:, user:, account:, uploads:)
      blobs = normalize_uploads!(Array(uploads).compact).map { ActiveStorage::Blob.create_and_upload!(**_1) }

      transaction do
        # Reloads the account's family under the lock, so a transfer that just committed fails
        # the family check instead of leaving the scan in the old family. The uploader is
        # locked first, in the order User#transfer_to_family! takes them.
        user.lock!
        account.lock!
        # Access is checked again under the locks: a member removed from the account since the
        # caller checked can't add to it.
        raise InvalidUpload, I18n.t("receipt_scans.errors.account_not_writable") unless Account.writable_by(user).exists?(account.id)

        scan = create!(family:, user:, account:)
        scan.files.attach(blobs)
        entry = account.entries.create!(
          name: I18n.t("receipt_scans.placeholder_name"),
          date: Date.current,
          amount: 0,
          currency: account.currency,
          entryable: Transaction.new(extra: { "receipt" => { "scan_id" => scan.id, "status" => "processing" } })
        )
        entry.entryable.attachments.attach(blobs)
        scan.update!(linked_transaction: entry.entryable)
        Ai::GenerationRun.enqueue(:extract_receipt, family:, ids: [ scan.id ])
        scan
      end
    rescue StandardError
      blobs&.each { _1.purge_later unless _1.attachments.exists? }
      raise
    end

    private
      def normalize_uploads!(uploads)
        raise InvalidUpload, I18n.t("receipt_scans.errors.no_files") if uploads.empty?
        raise InvalidUpload, I18n.t("receipt_scans.errors.too_many_files", count: MAX_FILES) if uploads.size > MAX_FILES

        files = uploads.map do |upload|
          raise InvalidUpload, I18n.t("receipt_scans.errors.not_a_file") unless upload.respond_to?(:original_filename) && upload.respond_to?(:read)

          if upload.size > MAX_FILE_SIZE
            raise InvalidUpload, I18n.t("receipt_scans.errors.too_large", size: MAX_FILE_SIZE / 1.megabyte)
          end

          ReceiptScan::ImageNormalizer.call(io: upload, content_type: upload.content_type, filename: upload.original_filename)
        rescue ReceiptScan::ImageNormalizer::TooManyPages
          raise InvalidUpload, I18n.t("receipt_scans.errors.too_many_pages", filename: upload.original_filename,
                                                                            count: Ai::Generations::ExtractReceipt::MAX_PDF_PAGES)
        rescue ReceiptScan::ImageNormalizer::UnsupportedFile
          raise InvalidUpload, I18n.t("receipt_scans.errors.unsupported_file", filename: upload.original_filename)
        end

        if files.many? && files.any? { |file| file[:content_type] == "application/pdf" }
          raise InvalidUpload, I18n.t("receipt_scans.errors.pdf_with_other_files")
        end

        files
      end
  end

  def flag!(reason_key, **details)
    update!(
      status: :needs_review,
      review_reasons: review_reasons + [ { "reason" => reason_key.to_s, **details.deep_stringify_keys } ]
    )
  end

  private
    def release_files
      @released_blob_ids = files_attachments.pluck(:blob_id)
      files_attachments.delete_all
    end

    def purge_unshared_files
      ActiveStorage::Blob.where(id: @released_blob_ids).where.missing(:attachments).find_each(&:purge_later)
    end

    def account_belongs_to_family
      return if account.nil? || family.nil?

      errors.add(:account, :invalid) unless account.family_id == family_id
    end
end
