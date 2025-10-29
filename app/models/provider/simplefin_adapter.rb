class Provider::SimplefinAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  # Register this adapter with the factory
  Provider::Factory.register("SimplefinAccount", self)

  # Configuration for SimpleFIN
  configure do
    description <<~DESC
      Setup instructions:
      1. Visit [SimpleFIN Bridge](https://bridge.simplefin.org/simplefin/create) to get a setup token
      2. This token is optional and only needed if you want to provide a default setup token for users
    DESC

    field :setup_token,
          label: "Setup Token",
          required: false,
          secret: true,
          env_key: "SIMPLEFIN_SETUP_TOKEN",
          description: "Optional: SimpleFIN setup token from your SimpleFIN Bridge account (one-time use)"
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
