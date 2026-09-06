class FamilyDocument < ApplicationRecord
  belongs_to :family
  # Optional: a tax return or a contract belongs to the family, not to one
  # account. Only a document that names an account is filtered on it.
  belongs_to :account, optional: true

  has_one_attached :file

  SUPPORTED_EXTENSIONS = VectorStore::Base::SUPPORTED_EXTENSIONS

  validates :filename, presence: true
  validates :status, inclusion: { in: %w[pending processing ready error] }

  # The account, when there is one, has to belong to the same family as the
  # document. Every write path today scopes its lookup, but the column is a
  # plain reference and a direct create or update would otherwise attach one
  # family's document to another family's account, which readable_by then
  # evaluates against the wrong owner.
  validate :account_belongs_to_family

  scope :ready, -> { where(status: "ready") }

  # A document is readable when it names no account, or names one the user can
  # reach. The store itself is family-wide, so this is the only thing standing
  # between one member's statements and another member's search.
  #
  # An account statement uploaded before anyone matched it has no account, and
  # "no account" must not mean "everyone": AccountStatement#viewable_by? gates
  # an unlinked statement on statement_manager?, so a guest reaching the vault
  # through search would otherwise read its text. Documents that are not
  # statements (a tax return, a contract) keep the family-wide behaviour.
  scope :readable_by, ->(user) {
    unlinked = where(account_id: nil)
    unlinked = unlinked.where("metadata->>'account_statement_id' IS NULL") unless AccountStatement.statement_manager?(user)

    unlinked.or(where(account_id: Account.accessible_by(user).select(:id)))
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

  private
    def account_belongs_to_family
      return if account_id.blank? || family_id.blank?
      return if account&.family_id == family_id

      errors.add(:account, :invalid)
    end
end
