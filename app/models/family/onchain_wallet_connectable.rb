# frozen_string_literal: true

module Family::OnchainWalletConnectable
  extend ActiveSupport::Concern

  included do
    has_many :onchain_wallet_items, dependent: :destroy
  end

  def can_connect_onchain_wallet?
    true
  end

  def onchain_wallet_item!
    onchain_wallet_items.active.first_or_create!(name: "On-chain Wallets").tap do |item|
      item.set_onchain_institution_defaults! if item.institution_name.blank?
    end
  end

  def has_onchain_wallet_credentials?
    onchain_wallet_items.active.any?(&:credentials_configured?)
  end
end
