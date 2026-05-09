module Account::Linkable
  extend ActiveSupport::Concern

  included do
    # New generic provider association
    has_many :account_providers, dependent: :destroy
    # Provider::Connection-framework link (Plaid, TrueLayer, etc.)
    has_one :provider_account, class_name: "Provider::Account", dependent: :nullify

    # Legacy SimpleFIN association — kept for backward compatibility until the
    # SimpleFIN migration. Plaid's legacy association was removed in the
    # Plaid framework cutover.
    belongs_to :simplefin_account, optional: true
  end

  # A "linked" account gets transaction and balance data from a third party
  # (Plaid, TrueLayer, SimpleFIN, etc.).
  def linked?
    account_providers.any? || provider_account.present? || simplefin_account.present?
  end

  # An "offline" or "unlinked" account is one where the user tracks values and
  # adds transactions manually, without the help of a data provider
  def unlinked?
    !linked?
  end
  alias_method :manual?, :unlinked?

  # Returns the primary provider adapter for this account
  # If multiple providers exist, returns the first one
  def provider
    return nil unless linked?

    @provider ||= account_providers.first&.adapter
  end

  # Returns all provider adapters for this account
  def providers
    @providers ||= account_providers.map(&:adapter).compact
  end

  # Returns the provider adapter for a specific provider type
  def provider_for(provider_type)
    account_provider = account_providers.find_by(provider_type: provider_type)
    account_provider&.adapter
  end

  # Convenience method to get the provider name
  def provider_name
    # Try new system first
    return provider&.provider_name if provider.present?

    # Fall back to legacy SimpleFIN system
    return "simplefin" if simplefin_account.present?

    nil
  end

  # Check if account is linked to a specific provider
  def linked_to?(provider_type)
    account_providers.exists?(provider_type: provider_type)
  end

  # Check if holdings can be deleted
  # If account has multiple providers, returns true only if ALL providers allow deletion
  # This prevents deleting holdings that would be recreated on next sync
  def can_delete_holdings?
    return true if unlinked?

    providers.all?(&:can_delete_holdings?)
  end
end
