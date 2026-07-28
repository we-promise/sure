# frozen_string_literal: true

module Family::WiseConnectable
  extend ActiveSupport::Concern

  included do
    has_many :wise_items, dependent: :destroy
  end

  def can_connect_wise?
    true
  end

  def create_wise_item!(token:, profile_id:, profile_type:, item_name:)
    item = wise_items.create!(
      token: token,
      profile_id: profile_id,
      profile_type: profile_type,
      name: item_name
    )

    item.sync_later

    item
  end
end
