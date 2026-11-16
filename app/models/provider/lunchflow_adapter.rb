class Provider::LunchflowAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("LunchflowAccount", self)
  declares_connection key: "lunchflow", name: "Lunch Flow", panel: { shape: :single },
                      metadata: { region: "Global", kinds: %w[Bank], maturity: :stable, logo_text: "LF", logo_color: "#f97316", domain: "lunchflow.app" },
                      lists: { settings_page: ->(items) { items.where.not(api_key: [ nil, "" ]).ordered.select(:id) } }

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  # One entry for the family, or one per credentialed connection when there
  # are several, so the user chooses which connection's accounts to link.
  def self.connection_configs(family:)
    return [] unless family.can_connect_lunchflow?

    lunchflow_items = family.lunchflow_items.active.with_credentials.ordered
    return [ connection_config_for(nil) ] unless lunchflow_items.many?

    lunchflow_items.map { |lunchflow_item| connection_config_for(lunchflow_item) }
  end

  def self.connection_config_for(lunchflow_item)
    path_params = ->(extra = {}) do
      lunchflow_item.present? ? extra.merge(lunchflow_item_id: lunchflow_item.id) : extra
    end

    {
      key: lunchflow_item.present? ? "lunchflow_#{lunchflow_item.id}" : "lunchflow",
      name: lunchflow_item.present? ? I18n.t("lunchflow_items.provider_connection.name", name: lunchflow_item.name) : I18n.t("lunchflow_items.provider_connection.default_name"),
      description: lunchflow_item.present? ? I18n.t("lunchflow_items.provider_connection.description", name: lunchflow_item.name) : I18n.t("lunchflow_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_lunchflow_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_lunchflow_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def provider_name
    "lunchflow"
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
