class AccountProvider < ApplicationRecord
  belongs_to :account
  belongs_to :provider, polymorphic: true

  validates :account_id, uniqueness: { scope: :provider_type }
  validates :provider_id, uniqueness: { scope: :provider_type }

  # Returns the provider adapter for this connection
  def adapter
    Provider::Factory.create_adapter(provider)
  end

  # Convenience method to get provider name
  def provider_name
    case provider_type
    when "PlaidAccount"
      "plaid"
    when "SimplefinAccount"
      "simplefin"
    else
      provider_type.underscore
    end
  end
end
