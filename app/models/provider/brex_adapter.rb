class Provider::BrexAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("BrexAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_brex?

    brex_items = family.brex_items.active.with_credentials.ordered

    return [ connection_config_for(nil) ] if brex_items.empty?

    brex_items.map { |brex_item| connection_config_for(brex_item) }
  end

  def provider_name
    "brex"
  end

  # Build a Brex provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Brex, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil, brex_item_id: nil)
    return nil unless family.present?

    brex_item = BrexItem.resolve_for(family: family, brex_item_id: brex_item_id)
    return nil unless brex_item&.credentials_configured?

    base_url = brex_item.effective_base_url
    return nil unless base_url.present?

    Provider::Brex.new(
      brex_item.token.to_s.strip,
      base_url: base_url
    )
  end

  def self.connection_config_for(brex_item)
    path_params = ->(extra = {}) do
      brex_item.present? ? extra.merge(brex_item_id: brex_item.id) : extra
    end

    {
      key: brex_item.present? ? "brex_#{brex_item.id}" : "brex",
      name: brex_item.present? ? I18n.t("brex_items.provider_connection.name", name: brex_item.name) : I18n.t("brex_items.provider_connection.default_name"),
      description: brex_item.present? ? I18n.t("brex_items.provider_connection.description", name: brex_item.name) : I18n.t("brex_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_brex_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_brex_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def sync_path
    Rails.application.routes.url_helpers.sync_brex_item_path(item)
  end

  def item
    provider_account.brex_item
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
        parsed_host = URI.parse(url).host
        Rails.logger.warn("Brex account #{provider_account.id} institution URL has no host: #{url}") if parsed_host.nil?
        domain = parsed_host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Brex account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    metadata = provider_account.institution_metadata

    metadata&.dig("name") || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata

    metadata&.dig("url") || item&.institution_url
  end

  def institution_color
    metadata = provider_account.institution_metadata

    metadata&.dig("color") || item&.institution_color
  end
end
