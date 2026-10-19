module Family::ScalableConnectable
  extend ActiveSupport::Concern

  included do
    has_many :scalable_items, dependent: :destroy
    has_many :scalable_accounts, through: :scalable_items
  end

  def can_connect_scalable?
    Rails.application.config.app_mode.self_hosted?
  end
end
