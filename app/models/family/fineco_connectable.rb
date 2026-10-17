module Family::FinecoConnectable
  extend ActiveSupport::Concern

  included do
    has_many :fineco_items, dependent: :destroy
    has_many :fineco_accounts, through: :fineco_items
  end

  def can_connect_fineco?
    Rails.application.config.app_mode.self_hosted?
  end
end
