class Provider::GocardlessAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("GocardlessAccount", self)

  # PSD2 account information covers payment accounts and card accounts. Loans are not
  # exposed by the GoCardless account endpoints, so they are deliberately not claimed.
  def self.supported_account_types
    %w[Depository CreditCard]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_gocardless?

    [ {
      key: "gocardless",
      name: "GoCardless",
      description: "Connect to your bank via GoCardless open banking (UK and EU)",
      can_connect: true,
      # Institution must be chosen before a requisition can be created, so the entry
      # point is the item's own new/select-bank flow rather than account selection.
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_gocardless_item_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_gocardless_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "gocardless"
  end

  # Build a Gocardless provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Gocardless, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Credentials are account-level at GoCardless, not per-connection, so any item
    # carrying a configured pair can supply them for the whole family. Matching
    # EnableBankingAdapter, the first fully-configured item wins.
    gocardless_item = family.gocardless_items.where.not(secret_id: nil).first
    return nil unless gocardless_item&.credentials_configured?

    Provider::Gocardless.new(
      secret_id: gocardless_item.secret_id,
      secret_key: gocardless_item.secret_key
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_gocardless_item_path(item)
  end

  def item
    provider_account.gocardless_item
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
        Rails.logger.warn("Invalid institution URL for Gocardless account #{provider_account.id}: #{url}")
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
