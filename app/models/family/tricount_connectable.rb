module Family::TricountConnectable
  extend ActiveSupport::Concern

  included do
    has_many :tricount_items, dependent: :destroy
  end

  def can_connect_tricount?
    # Families can configure their own Tricount credentials
    true
  end

  def create_tricount_item!(sharing_tokens:, session_token:, app_installation_uuid: nil, client_public_key: nil, tricount_user_id: nil, item_name: nil)
    tricount_item = tricount_items.create!(
      name: item_name || "Tricount Connection",
      sharing_tokens: sharing_tokens,
      session_token: session_token,
      app_installation_uuid: app_installation_uuid,
      client_public_key: client_public_key,
      tricount_user_id: tricount_user_id
    )

    tricount_item.sync_later

    tricount_item
  end

  def has_tricount_credentials?
    tricount_items.where.not(sharing_tokens: nil).exists?
  end
end
