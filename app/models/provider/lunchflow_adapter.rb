class Provider::LunchflowAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("LunchflowAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Depository CreditCard Loan]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_lunchflow?

    [ {
      key: "lunchflow",
      name: "Lunch Flow",
      description: "Connect to your bank via Lunch Flow",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_lunchflow_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_lunchflow_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "lunchflow"
  end

  # Build a Lunch Flow provider instance with family-specific credentials
  # Lunchflow is now fully per-family - no global credentials supported
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Lunchflow, nil] Returns nil if API key is not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    lunchflow_item = family.lunchflow_items.where.not(api_key: nil).first
    return nil unless lunchflow_item&.credentials_configured?

    Provider::Lunchflow.new(
      lunchflow_item.api_key,
      base_url: lunchflow_item.effective_base_url
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_lunchflow_item_path(item)
  end

  def item
    provider_account.lunchflow_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    # Lunch Flow may provide institution metadata in account data
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Lunch Flow account #{provider_account.id}: #{url}")
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
