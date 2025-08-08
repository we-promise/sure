module Family::SimplefinConnectable
  extend ActiveSupport::Concern

  included do
    has_many :simplefin_items, dependent: :destroy
  end

  def can_connect_simplefin?
    true # SimpleFin doesn't have regional restrictions like Plaid
  end

  def create_simplefin_item!(setup_token:, item_name: nil)
    simplefin_provider = Provider::Simplefin.new
    access_url = simplefin_provider.claim_access_url(setup_token)

    simplefin_item = simplefin_items.create!(
      name: item_name || "SimpleFin Connection",
      access_url: access_url
    )

    simplefin_item.sync_later

    simplefin_item
  end
end
