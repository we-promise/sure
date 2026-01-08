class Provider::TraderepublicAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("TraderepublicAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Investment Depository]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_traderepublic?

    [ {
      key: "traderepublic",
      name: "Trade Republic",
      description: "Connect to your Trade Republic account",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_traderepublic_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_traderepublic_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "traderepublic"
  end

  # Build a Trade Republic provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Traderepublic, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    traderepublic_item = family.traderepublic_items.where.not(phone_number: nil).first
    return nil unless traderepublic_item&.credentials_configured?

    Provider::Traderepublic.new(
      phone_number: traderepublic_item.phone_number,
      pin: traderepublic_item.pin
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_traderepublic_item_path(item)
  end

  def item
    provider_account.traderepublic_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    "traderepublic.com"
  end

  def institution_name
    "Trade Republic"
  end

  def institution_url
    "https://traderepublic.com"
  end

  def institution_color
    "#00D69E"
  end

  private

  def provider_account
    @provider_account ||= TraderepublicAccount.find(@account_provider.provider_id)
  end
end
