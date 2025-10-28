class AccountProvider < ApplicationRecord
  belongs_to :account
  belongs_to :provider, polymorphic: true

  validates :account_id, uniqueness: { scope: :provider_type }
  validates :provider_id, uniqueness: { scope: :provider_type }

  # Returns the provider adapter for this connection
  def adapter
    Provider::Factory.create_adapter(provider, account: account)
  end

  # Convenience method to get provider name
  # Delegates to the adapter for consistency, falls back to underscored provider_type
  def provider_name
    adapter&.provider_name || provider_type.underscore
  end
end
