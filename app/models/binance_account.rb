# frozen_string_literal: true

class BinanceAccount < ApplicationRecord
  belongs_to :binance_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  validates :name, :currency, presence: true
end
