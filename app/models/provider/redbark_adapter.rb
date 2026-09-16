class Provider::RedbarkAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("RedbarkAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Depository CreditCard Loan]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_redbark?

    [ {
      key: "redbark",
      name: "Redbark",
      description: "Connect your Australian bank accounts via Redbark",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_redbark_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_redbark_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "redbark"
  end

  # Build a Redbark provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Redbark, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    redbark_item = family.redbark_items.where.not(api_key: nil).first
    return nil unless redbark_item&.credentials_configured?

    Provider::Redbark.new(api_key: redbark_item.api_key)
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_redbark_item_path(item)
  end

  def item
    provider_account.redbark_item
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
        Rails.logger.warn("Invalid institution URL for Redbark account #{provider_account.id}: #{url}")
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
