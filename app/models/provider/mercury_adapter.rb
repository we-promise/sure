class Provider::MercuryAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("MercuryAccount", self)

  # Define which account types this provider supports
  # Mercury is primarily a business banking provider with checking/savings accounts
  def self.supported_account_types
    %w[Depository]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_mercury?

    mercury_items = family.mercury_items.active.ordered.select(&:credentials_configured?)

    return [ connection_config_for(nil) ] if mercury_items.empty?

    mercury_items.map { |mercury_item| connection_config_for(mercury_item) }
  end

  def provider_name
    "mercury"
  end

  # Build a Mercury provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Mercury, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil, mercury_item_id: nil)
    return nil unless family.present?

    mercury_item = resolve_mercury_item(family, mercury_item_id)
    return nil unless mercury_item&.credentials_configured?

    Provider::Mercury.new(
      mercury_item.token.to_s.strip,
      base_url: mercury_item.effective_base_url
    )
  end

  def self.connection_config_for(mercury_item)
    path_params = ->(extra = {}) do
      mercury_item.present? ? extra.merge(mercury_item_id: mercury_item.id) : extra
    end

    {
      key: mercury_item.present? ? "mercury_#{mercury_item.id}" : "mercury",
      name: mercury_item.present? ? I18n.t("mercury_items.provider_connection.name", name: mercury_item.name) : I18n.t("mercury_items.provider_connection.default_name"),
      description: mercury_item.present? ? I18n.t("mercury_items.provider_connection.description", name: mercury_item.name) : I18n.t("mercury_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_mercury_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_mercury_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def self.resolve_mercury_item(family, mercury_item_id)
    if mercury_item_id.present?
      item = family.mercury_items.active.find_by(id: mercury_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    family.mercury_items.active.ordered.find(&:credentials_configured?)
  end
  private_class_method :resolve_mercury_item

  def sync_path
    Rails.application.routes.url_helpers.sync_mercury_item_path(item)
  end

  def item
    provider_account.mercury_item
  end

  def can_delete_holdings?
    false
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
        Rails.logger.warn("Invalid institution URL for Mercury account #{provider_account.id}: #{url}")
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
