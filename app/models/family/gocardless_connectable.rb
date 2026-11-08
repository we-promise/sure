module Family::GocardlessConnectable
  extend ActiveSupport::Concern

  included do
    has_many :gocardless_items, dependent: :destroy
  end

  def can_connect_gocardless?
    # Families can configure their own Gocardless credentials
    true
  end

  def create_gocardless_item!(secret_id:, secret_key:, institution_id: nil, institution_name: nil, requisition_id: nil, agreement_id: nil, requisition_status: nil, item_name: nil)
    gocardless_item = gocardless_items.create!(
      name: item_name || "Gocardless Connection",
      secret_id: secret_id,
      secret_key: secret_key,
      institution_id: institution_id,
      institution_name: institution_name,
      requisition_id: requisition_id,
      agreement_id: agreement_id,
      requisition_status: requisition_status
    )

    gocardless_item.sync_later

    gocardless_item
  end

  def has_gocardless_credentials?
    gocardless_items.where.not(secret_id: nil).exists?
  end
end
