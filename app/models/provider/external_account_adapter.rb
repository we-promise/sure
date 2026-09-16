# Shared account-facing presentation. API acquisition lives in AccountData
# adapters; this object supplies the interface used by existing account screens.
class Provider::ExternalAccountAdapter < Provider::Base
  include Provider::Syncable, Provider::InstitutionMetadata

  Provider::Factory.register("ExternalAccount", self)

  def provider_name
    provider_account.provider_key
  end

  def item
    provider_account.provider_connection
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_account_path(account)
  end

  def institution_name
    institution["name"].presence || item.name
  end

  def institution_domain
    institution["domain"]
  end

  def institution_url
    institution["url"]
  end

  def institution_color
    institution["color"]
  end

  def raw_payload
    provider_account.ingestion_batches.where(origin_kind: "provider").order(created_at: :desc).first&.payload
  end

  private
    def institution
      provider_account.metadata.fetch("institution", {})
    end
end
