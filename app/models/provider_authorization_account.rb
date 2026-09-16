class ProviderAuthorizationAccount < ApplicationRecord
  include ProviderDataOwnership

  belongs_to :family
  belongs_to :provider_connection
  belongs_to :provider_authorization
  belongs_to :external_account

  enum :status, { active: "active", revoked: "revoked" }, default: :active, validate: true

  before_validation :inherit_ownership
  validates :external_account_id, uniqueness: { scope: :provider_authorization_id }
  validate :same_connection

  private
    def inherit_ownership
      self.family_id ||= provider_authorization&.family_id
      self.provider_connection_id ||= provider_authorization&.provider_connection_id
    end

    def same_connection
      validate_family_of(provider_connection, :provider_connection)
      validate_connection_of(provider_authorization, :provider_authorization)
      validate_connection_of(external_account, :external_account)
    end
end
