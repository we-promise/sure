class Provider::PlaidAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("PlaidAccount", self)

  def provider_name
    "plaid"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_plaid_item_path(item)
  end

  def item
    provider_account.plaid_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    url_string = item&.institution_url
    return nil unless url_string.present?

    begin
      uri = URI.parse(url_string)
      uri.host&.gsub(/^www\./, "")
    rescue URI::InvalidURIError
      Rails.logger.warn("Invalid institution URL for Plaid account #{provider_account.id}: #{url_string}")
      nil
    end
  end

  def institution_name
    item&.name
  end

  def institution_url
    item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
