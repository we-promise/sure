class Provider::SimplefinAdapter < Provider::Base
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

  def status
    item&.status
  end

  def requires_update?
    status == "requires_update"
  end
end
