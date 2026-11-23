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

  has_many_attached :files

  enum :status, {
    processing: "processing",
    completed: "completed",
    needs_review: "needs_review",
    failed: "failed"
  }, validate: true

  validate :account_belongs_to_family

  InvalidUpload = Class.new(StandardError)

  class << self
    # Whether receipts can be read for this family and user: the AI route allows it, its model
    # can read images, and the preferred provider reads receipts (only Anthropic so far). A
    # custom endpoint declares what its model can do in the AI configuration.
    def extraction_available?(family:, user:)
      model = Ai.plan(:extract_receipt, family:, user:)&.model
      model.present? && model.capable?(:vision) && extraction_provider.present?
    end

    # The preferred LLM provider, as other AI features use, when it can read receipts. Never
    # another configured provider: receipts go only where the instance sends its AI work.
    def extraction_provider
      provider = Provider::Registry.preferred_llm_provider
      provider if provider&.supports_receipt_extraction?
    end

    # Stores the normalized files and gives the user a "Processing receipt…" transaction on the
    # account right away; ReceiptScan::ProcessJob fills it in. The caller authorizes the account.
    def create_from_upload!(family:, user:, account:, uploads:)
      normalized = normalize_uploads!(Array(uploads).compact)

      scan = nil
      begin
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
          normalized.each { |file| scan.files.attach(**file) }

          entry = account.entries.create!(
            name: I18n.t("receipt_scans.placeholder_name"),
            date: Date.current,
            amount: 0,
            currency: account.currency,
            entryable: Transaction.new(extra: { "receipt" => { "scan_id" => scan.id, "status" => "processing" } })
          )
          entry.entryable.attachments.attach(scan.files.blobs)
          scan.update!(linked_transaction: entry.entryable)
        end
      rescue StandardError => e
        # Active Storage uploads the files after the commit; when that fails the scan exists
        # without readable files, so it ends as failed rather than being read.
        raise unless scan&.persisted? && exists?(scan.id)

        ReceiptScan::Processor.new(scan.reload).fail!(e)
        return scan
      end

      enqueue_processing(scan)
      scan
    end

    private
      # A scan nothing will read would stay "processing" forever: end it as failed, so the user
      # sees it and can try again.
      def enqueue_processing(scan)
        error = nil
        enqueued = begin
          ReceiptScan::ProcessJob.perform_later(scan)
        rescue StandardError => e
          error = e
          false
        end
        ReceiptScan::Processor.new(scan).fail!(error || StandardError.new("The receipt couldn't be queued for reading")) unless enqueued
      end

      def normalize_uploads!(uploads)
        raise InvalidUpload, I18n.t("receipt_scans.errors.no_files") if uploads.empty?
        raise InvalidUpload, I18n.t("receipt_scans.errors.too_many_files", count: MAX_FILES) if uploads.size > MAX_FILES

        files = uploads.map do |upload|
          if upload.size > MAX_FILE_SIZE
            raise InvalidUpload, I18n.t("receipt_scans.errors.too_large", size: MAX_FILE_SIZE / 1.megabyte)
          end

          ReceiptScan::ImageNormalizer.call(io: upload, content_type: upload.content_type, filename: upload.original_filename)
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
    def account_belongs_to_family
      return if account.nil? || family.nil?

      errors.add(:account, :invalid) unless account.family_id == family_id
    end
end
