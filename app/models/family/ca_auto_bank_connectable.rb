module Family::CaAutoBankConnectable
  extend ActiveSupport::Concern

  included do
    has_many :ca_auto_bank_items, dependent: :destroy
    has_many :ca_auto_bank_accounts, through: :ca_auto_bank_items
  end

  def can_connect_ca_auto_bank?
    Rails.application.config.app_mode.self_hosted?
  end
end
