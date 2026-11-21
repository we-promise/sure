class FamilyDocument < ApplicationRecord
  belongs_to :family
  # Optional: a tax return or a contract belongs to the family, not to one
  # account. Only a document that names an account is filtered on it.
  belongs_to :account, optional: true

  has_one_attached :file

  SUPPORTED_EXTENSIONS = VectorStore::Base::SUPPORTED_EXTENSIONS

  validates :filename, presence: true
  # unreadable: indexed with no text (a scan an OpenAI store's file search can't read).
  STATUSES = %w[pending processing ready unreadable error].freeze
  validates :status, inclusion: { in: STATUSES }

  # readable_by trusts the account, so it has to be the document's family's.
  validate :account_belongs_to_family

  scope :ready, -> { where(status: "ready") }
  # Rows that only keep an uploaded file's id for cleanup: its attachment and its compensating
  # deletion both failed (Family#upload_document). They are not search copies.
  scope :unattached, -> { where.not("metadata->>'cleanup_error' IS NULL") }
  scope :search_copies, -> { where("metadata->>'cleanup_error' IS NULL") }

  # The documents a user may read, among those whose indexing succeeded (an error or unreadable
  # one has nothing usable): those on an account they can reach, and those with no account. The
  # store is family-wide, so this is the only filter between members. A statement not yet
  # matched to an account follows AccountStatement#viewable_by?: statement managers only. Other
  # documents without an account (a tax return) are the whole family's.
  scope :readable_by, ->(user) {
    unlinked = where(account_id: nil)
    unlinked = unlinked.where("metadata->>'account_statement_id' IS NULL") unless AccountStatement.statement_manager?(user)

    unlinked.or(where(account_id: Account.accessible_by(user).select(:id)))
            .where(status: "ready")
  }

  # Watches an asynchronous index until it settles (VectorStore::IndexStatusJob). The enqueue runs
  # after commit, so a queue failure must not fail the insert: the row and its file are already in
  # the store and can be polled again.
  after_create_commit :poll_index_later, if: -> { status == "processing" }

  # Recovery for a copy still `processing` whose poll was lost (the queue was down when it was
  # created, or a requeue was rejected): polling again is harmless.
  def self.requeue_index_polls = where(status: "processing").find_each(&:poll_index_later)

  def poll_index_later
    # A reread of the same document resumes a copy whose poll cap was reached while the provider
    # was still indexing. Other errors stay terminal: they need a new upload/copy, not another poll.
    if status == "error" && metadata.to_h["indexing_timeout"]
      update!(status: "processing", metadata: metadata.to_h.except("indexing_timeout"))
    end
    return false unless status == "processing"

    VectorStore::IndexStatusJob.perform_later(self)
    true
  rescue StandardError => e
    DebugLogEntry.capture(
      category: "documents",
      level: "warn",
      message: "Couldn't queue an index poll for an uploaded document: #{e.class}",
      source: "FamilyDocument#poll_index_later",
      family: family,
      metadata: { family_document_id: id }
    )
    false
  end

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

  private
    def account_belongs_to_family
      return if account_id.blank? || family_id.blank?
      return if account&.family_id == family_id

      errors.add(:account, :invalid)
    end
end
