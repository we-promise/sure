class Provider::EmailAlertAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("EmailAlertAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Depository CreditCard Loan]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_email_alert?

    [ {
      key: "email_alert",
      name: I18n.t("email_alert_items.default_name"),
      description: I18n.t("email_alert_items.panel.intro", institutions: EmailAlert::Parsers.supported_institutions.to_sentence),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_email_alert_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_email_alert_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "email_alert"
  end

  # Alerts are pushed to Sure by email, so there is no API client to build.
  def self.build_provider(family: nil)
    nil
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_email_alert_item_path(item)
  end

  def item
    provider_account.email_alert_item
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
        Rails.logger.warn("Invalid institution URL for EmailAlert account #{provider_account.id}: #{url}")
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
