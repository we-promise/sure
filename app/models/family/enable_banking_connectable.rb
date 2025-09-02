module Family::EnableBankingConnectable
  extend ActiveSupport::Concern

  included do
    has_many :enable_banking_items, dependent: :destroy
  end

  def create_enable_banking_item!(session_id:, valid_until:, item_name: nil,logo_url: nil, raw_payload: {})
    enable_banking_item = enable_banking_items.create!(
      session_id: session_id,
      valid_until: valid_until,
      name: item_name,
      logo_url: logo_url,
      raw_payload: raw_payload
    )

    enable_banking_item.sync_later

    enable_banking_item
  end
end
