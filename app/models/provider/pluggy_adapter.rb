class Provider::PluggyAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("PluggyAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    # Banking providers typically support these account types
    %w[Depository CreditCard Loan Investment]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_pluggy?

    [ {
      key: "pluggy",
      name: "Pluggy",
      description: "Connect to your bank via Pluggy",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_pluggy_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_pluggy_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "pluggy"
  end

  # Build a Pluggy provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Pluggy, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    pluggy_item = family.pluggy_items.where.not(client_id: nil).first
    return nil unless pluggy_item&.credentials_configured?

    # TODO: Implement provider initialization
    # Provider::Pluggy.new(
    #   pluggy_item.client_id
    # )
    raise NotImplementedError, "Implement Provider::Pluggy.new in #{__FILE__}"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_pluggy_item_path(item)
  end

  def item
    provider_account.pluggy_item
  end


  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Pluggy account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
