class AccountProvider < ApplicationRecord
  belongs_to :account
  belongs_to :provider, polymorphic: true

  validates :account_id, uniqueness: { scope: :provider_type }
  validates :provider_id, uniqueness: { scope: :provider_type }

  # When unlinking a CoinStats account, also destroy the CoinstatsAccount record
  # so it doesn't remain orphaned and count as "needs setup".
  # Other providers may legitimately enter a "needs setup" state.
  after_destroy :destroy_coinstats_provider_account, if: :coinstats_provider?

  # Returns the provider adapter for this connection
  def adapter
    Provider::Factory.create_adapter(provider, account: account)
  end

  # Convenience method to get provider name
  # Delegates to the adapter for consistency, falls back to underscored provider_type
  def provider_name
    adapter&.provider_name || provider_type.underscore
  end

  private

    def coinstats_provider?
      provider_type == "CoinstatsAccount"
    end

    def destroy_coinstats_provider_account
      provider&.destroy
    end
end
