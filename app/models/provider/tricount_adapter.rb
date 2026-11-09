class Provider::TricountAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("TricountAccount", self)

  # A tricount is a running position with the group, owed either way, so it
  # is a cash account whose balance can go below zero.
  def self.supported_account_types
    %w[Depository]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_tricount?

    [ {
      key: "tricount",
      name: "Tricount",
      description: I18n.t("tricount_items.provider_connection.description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_tricount_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_tricount_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "tricount"
  end

  # Build a Tricount provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Tricount, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    tricount_item = family.tricount_items.active.where.not(sharing_tokens: nil).first
    tricount_item&.tricount_provider
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_tricount_item_path(item)
  end

  def item
    provider_account.tricount_item
  end


  def institution_domain
    TricountItem::INSTITUTION[:domain]
  end

  def institution_name
    TricountItem::INSTITUTION[:name]
  end

  def institution_url
    TricountItem::INSTITUTION[:url]
  end

  def institution_color
    item&.institution_color
  end
end
