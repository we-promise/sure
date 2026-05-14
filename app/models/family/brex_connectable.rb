# frozen_string_literal: true

module Family::BrexConnectable
  extend ActiveSupport::Concern

  included do
    has_many :brex_items, dependent: :destroy
  end

  def can_connect_brex?
    true
  end

  def create_brex_item!(token:, base_url: nil, item_name: nil)
    brex_item = brex_items.create!(
      name: item_name.presence || I18n.t("brex_items.default_connection_name"),
      token: token,
      base_url: base_url
    )

    brex_item.sync_later

    brex_item
  end

  def has_brex_credentials?
    brex_items.active.with_credentials.exists?
  end
end
