module Family::SophtronConnectable
  extend ActiveSupport::Concern

  included do
    has_many :sophtron_items, dependent: :destroy
  end

  def can_connect_sophtron?
    # Families can now configure their own Sophtron credentials
    true
  end

  def create_sophtron_item!(user_id:, access_key:, base_url: nil, item_name: nil)
    sophtron_item = sophtron_items.create!(
      name: item_name || "Sophtron Connection",
      user_id: user_id,
      access_key: access_key,
      base_url: base_url
    )

    sophtron_item.sync_later

    sophtron_item
  end

  def has_sophtron_credentials?
    sophtron_items.where.not(user_id: [ nil, "" ], access_key: [ nil, "" ]).exists?
  end
end
