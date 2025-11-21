class Provider::SimplefinAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  # Register this adapter with the factory
  Provider::Factory.register("SimplefinAccount", self)

  # Configuration for SimpleFIN
  # NOTE: Global setup_token is DEPRECATED. Families should configure their own SimpleFIN connections.
  configure do
    description <<~DESC
      **DEPRECATED:** Global SimpleFIN setup token configuration is deprecated.

      SimpleFIN connections are now configured per-family for better security and multi-tenancy support.
      Each family should configure their own SimpleFIN connection with their own setup token.

      This global configuration is maintained for backward compatibility only and will be removed in a future version.
    DESC

    field :setup_token,
          label: "Setup Token (Deprecated)",
          required: false,
          secret: true,
          env_key: "SIMPLEFIN_SETUP_TOKEN",
          description: "DEPRECATED: Global setup token. Use family-specific SimpleFIN connections instead."
  end

  def provider_name
    "simplefin"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_simplefin_item_path(item)
  end

  def item
    provider_account.simplefin_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    org_data = provider_account.org_data
    return nil unless org_data.present?

    domain = org_data["domain"]
    url = org_data["url"] || org_data["sfin-url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for SimpleFin account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    org_data = provider_account.org_data
    return nil unless org_data.present?

    org_data["name"] || item&.institution_name
  end

  def institution_url
    org_data = provider_account.org_data
    return nil unless org_data.present?

    org_data["url"] || org_data["sfin-url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
