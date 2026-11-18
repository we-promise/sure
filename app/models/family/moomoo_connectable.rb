module Family::MoomooConnectable
  extend ActiveSupport::Concern

  included do
    has_many :moomoo_items, dependent: :destroy
  end

  def can_connect_moomoo?
    true
  end

  # Reuses a connection that never finished authorizing, so repeated Connect
  # clicks don't pile up connections, then makes sure it has an OAuth client
  # for this redirect URI. A connection created here is removed again if
  # moomoo refuses the registration; one a consent completes meanwhile is left
  # to it, and another is used.
  def moomoo_item_for_new_connection(redirect_uri:)
    item = moomoo_items.active.where(refresh_token: nil).ordered.first
    created = item.nil?
    item ||= moomoo_items.create!(name: I18n.t("moomoo_items.default_name"))

    begin
      item.ensure_oauth_client!(redirect_uri: redirect_uri)
    rescue Provider::Moomoo::MoomooError => e
      return moomoo_item_for_new_connection(redirect_uri: redirect_uri) if e.error_type == :already_connected

      # A consent from another tab may have completed it meanwhile.
      item.with_lock { item.destroy unless item.connected? } if created
      raise
    end

    item
  end
end
