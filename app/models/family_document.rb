class FamilyDocument < ApplicationRecord
  belongs_to :family
  # Optional: a tax return or a contract belongs to the family, not to one
  # account. Only a document that names an account is filtered on it.
  belongs_to :account, optional: true

  has_one_attached :file

  SUPPORTED_EXTENSIONS = VectorStore::Base::SUPPORTED_EXTENSIONS

  validates :filename, presence: true
  validates :status, inclusion: { in: %w[pending processing ready error] }

  scope :ready, -> { where(status: "ready") }

  # A document is readable when it names no account, or names one the user can
  # reach. The store itself is family-wide, so this is the only thing standing
  # between one member's statements and another member's search.
  scope :readable_by, ->(user) {
    where(account_id: nil).or(where(account_id: Account.accessible_by(user).select(:id)))
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
