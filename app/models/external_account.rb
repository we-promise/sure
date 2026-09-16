class ExternalAccount < ApplicationRecord
  include ProviderDataEncryption, ProviderDataOwnership

  encrypted_document :sensitive_details

  belongs_to :family
  belongs_to :provider_connection
  has_one :account_provider, dependent: :restrict_with_error
  has_one :account, through: :account_provider
  has_many :provider_authorization_accounts, dependent: :destroy
  has_many :provider_authorizations, through: :provider_authorization_accounts
  has_many :ingestion_batches, dependent: :restrict_with_error
  has_many :provider_sync_checkpoints, dependent: :restrict_with_error

  enum :status, { active: "active", ignored: "ignored", closed: "closed", identity_unresolved: "identity_unresolved" }, default: :active, validate: true

  scope :linked, -> { joins(:account_provider) }
  scope :unlinked, -> { where.missing(:account_provider) }

  before_validation :inherit_connection_identity
  validates :identity_namespace, :name, presence: true
  validates :currency, presence: true, if: :reported_balance?
  validates :external_id, presence: true, unless: :identity_unresolved?
  validates :external_id, uniqueness: { scope: [ :provider_connection_id, :identity_namespace ] }, allow_nil: true
  validate :ownership_and_documents
  validate :stable_identity
  validate :known_currency

  def current_account
    account
  end

  private
    def reported_balance?
      [ current_balance, available_balance, cash_balance, reserved_balance ].any? { |value| !value.nil? }
    end

    def inherit_connection_identity
      self.family_id ||= provider_connection&.family_id
      self.provider_key ||= provider_connection&.provider_key
    end

    def ownership_and_documents
      validate_family_of(provider_connection, :provider_connection)
      if provider_connection && provider_key != provider_connection.provider_key
        errors.add(:provider_key, "must match the provider connection")
      end
      validate_documents(:metadata, :sensitive_details)
    end

    def stable_identity
      return if new_record?

      %w[family_id provider_connection_id provider_key identity_namespace].each do |attribute|
        errors.add(attribute, "cannot change") if will_save_change_to_attribute?(attribute)
      end
      if external_id_in_database.present? && will_save_change_to_external_id?
        errors.add(:external_id, "cannot change; retain replacement identifiers as aliases")
      end
    end

    def known_currency
      return if currency.blank?

      Money::Currency.new(currency)
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      errors.add(:currency, "is not a supported currency")
    end
end
