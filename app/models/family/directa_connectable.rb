module Family::DirectaConnectable
  extend ActiveSupport::Concern

  included do
    has_many :directa_items, dependent: :destroy
    has_many :directa_accounts, through: :directa_items
  end

  def can_connect_directa?
    Rails.application.config.app_mode.self_hosted?
  end
end
