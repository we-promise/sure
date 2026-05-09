class Provider::FamilyConfig < ApplicationRecord
  include Encryptable

  self.table_name = "provider_family_configs"

  # Today every BYOK adapter takes the same shape (client_id + client_secret,
  # plus an optional sandbox flag for providers that distinguish test/prod
  # endpoints — TrueLayer being the current example).
  # When an adapter wants different keys, swap to a per-adapter
  # `credential_keys` hook on Provider::Registry.
  ALLOWED_CREDENTIAL_KEYS = %w[client_id client_secret sandbox].freeze

  belongs_to :family
  has_many :provider_connections, class_name: "Provider::Connection",
                                   foreign_key: :provider_family_config_id,
                                   dependent: :destroy

  if encryption_ready?
    encrypts :credentials
  end

  validates :provider_key, presence: true,
                            uniqueness: { scope: :family_id },
                            format: { with: /\A[a-z0-9_]+\z/, message: "only allows lowercase letters, numbers, and underscores" }
  validate :credential_keys_are_known
  validate :credentials_are_complete

  def client_id     = credentials&.fetch("client_id", nil)
  def client_secret = credentials&.fetch("client_secret", nil)
  def sandbox       = ActiveModel::Type::Boolean.new.cast(credentials&.fetch("sandbox", false))

  def client_id=(value)
    self.credentials = (credentials || {}).merge("client_id" => value)
  end

  def client_secret=(value)
    self.credentials = (credentials || {}).merge("client_secret" => value)
  end

  def sandbox=(value)
    self.credentials = (credentials || {}).merge("sandbox" => ActiveModel::Type::Boolean.new.cast(value))
  end

  private

    def credential_keys_are_known
      return if credentials.blank?
      unknown = credentials.keys - ALLOWED_CREDENTIAL_KEYS
      return if unknown.empty?
      errors.add(:credentials, "contains unsupported keys: #{unknown.sort.join(', ')}")
    end

    # Save-time guard so the form fails fast rather than silently accepting a
    # config that will only blow up when the OAuth flow starts.
    def credentials_are_complete
      return if client_id.present? && client_secret.present?
      errors.add(:credentials, "must include client_id and client_secret")
    end
end
