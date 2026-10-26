class FamilyDocument < ApplicationRecord
  belongs_to :family
  # Optional: a tax return or a contract belongs to the family, not to one
  # account. Only a document that names an account is filtered on it.
  belongs_to :account, optional: true

  has_one_attached :file

  SUPPORTED_EXTENSIONS = VectorStore::Base::SUPPORTED_EXTENSIONS

  # What a document is, independent of whether it can be searched. A tax form's
  # specific form ("W-2", "1099-B", "1098") is finer than a kind and lives in
  # metadata["form"].
  KINDS = %w[
    account_statement tax_form tax_return pay_stub insurance_policy
    insurance_claim contract receipt invoice loan_document
    investment_report benefits_statement id_document other
  ].freeze

  # The classifier behind PdfImport answers with Import::DOCUMENT_TYPES, a
  # coarser and older vocabulary. Each of those maps onto exactly one kind.
  IMPORT_DOCUMENT_TYPE_KINDS = {
    "account_statement" => "account_statement",
    "bank_statement" => "account_statement",
    "credit_card_statement" => "account_statement",
    "investment_statement" => "investment_report",
    "financial_document" => "other",
    "contract" => "contract",
    "other" => "other"
  }.freeze

  # Earliest year anyone plausibly files away; the upper bound is next year,
  # because January brings estimated-tax vouchers and early forms for it.
  MIN_TAX_YEAR = 1900

  ISSUER_NAME_MAX_LENGTH = 200
  TITLE_MAX_LENGTH = 255

  normalizes :issuer_name, :title, with: ->(value) { value.to_s.squish.presence }

  validates :filename, presence: true
  validates :status, inclusion: { in: %w[pending processing ready error] }
  validates :kind, inclusion: { in: KINDS }
  validates :tax_year, numericality: {
    only_integer: true,
    greater_than_or_equal_to: MIN_TAX_YEAR,
    less_than_or_equal_to: ->(_document) { Date.current.year + 1 }
  }, allow_nil: true
  validates :issuer_name, length: { maximum: ISSUER_NAME_MAX_LENGTH }
  validates :title, length: { maximum: TITLE_MAX_LENGTH }
  validates :content_sha256, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :content_sha256, uniqueness: { scope: :family_id }, allow_nil: true

  # The account, when there is one, has to belong to the same family as the
  # document. Every write path today scopes its lookup, but the column is a
  # plain reference and a direct create or update would otherwise attach one
  # family's document to another family's account, which readable_by then
  # evaluates against the wrong owner.
  validate :account_belongs_to_family

  scope :ready, -> { where(status: "ready") }
  scope :of_kind, ->(kind) { where(kind: kind) }
  scope :for_tax_year, ->(year) { where(tax_year: year) }

  def self.kind_for_import_type(type)
    IMPORT_DOCUMENT_TYPE_KINDS.fetch(type.to_s, "other")
  end

  def self.kind_label(kind)
    I18n.t("activerecord.attributes.family_document.kinds.#{kind}", default: kind.to_s.humanize)
  end

  def self.content_digest(content)
    Digest::SHA256.hexdigest(content.to_s)
  end

  def kind_label
    self.class.kind_label(kind)
  end

  def display_name
    title.presence || filename
  end

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
