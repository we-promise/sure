module Family::SimplefinConnectable
  extend ActiveSupport::Concern

  included do
    has_many :simplefin_items, dependent: :destroy
  end

  def can_connect_simplefin?
    true # SimpleFin doesn't have regional restrictions like Plaid
  end

  def create_simplefin_item!(setup_token:, item_name: nil)
    claim = SimplefinItem::ConnectionUpdate.prepare_new(self, setup_token: setup_token, item_name: item_name)
    SimplefinItem::ConnectionUpdate.perform(claim_id: claim.id, family_id: id)
  end
end
