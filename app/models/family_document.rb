class FamilyDocument < ApplicationRecord
  belongs_to :family
  # The statement a processed PDF came from (ProcessPdfJob).
  belongs_to :account_statement, optional: true

  has_one_attached :file

  SUPPORTED_EXTENSIONS = VectorStore::Base::SUPPORTED_EXTENSIONS

  validates :filename, presence: true
  validates :status, inclusion: { in: %w[pending processing ready error] }

  scope :ready, -> { where(status: "ready") }

  # The documents whose excerpts +user+ may find. A statement PDF follows its
  # statement (AccountStatement#viewable_by?), and a file uploaded straight to
  # the store is the family's. A PDF processed before documents recorded their
  # statement carries only its document type and could come from any account,
  # so nobody finds it until it is linked.
  scope :searchable_by, ->(user) {
    where(family_id: user.family_id).merge(
      where(account_statement_id: AccountStatement.viewable_by(user).select(:id))
        .or(where(account_statement_id: nil).where.not(Arel.sql("family_documents.metadata ? 'type'")))
    )
  }

  def mark_ready!
    update!(status: "ready")
  end

  def mark_error!(error_message = nil)
    update!(status: "error", metadata: (metadata || {}).merge("error" => error_message))
  end

  def supported_extension?
    ext = File.extname(filename).downcase
    SUPPORTED_EXTENSIONS.include?(ext)
  end
end
