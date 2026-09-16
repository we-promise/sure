module Family::SnaptradeConnectable
  extend ActiveSupport::Concern

  included do
    has_many :snaptrade_items, dependent: :destroy
  end

  def can_connect_snaptrade?
    # Families can connect to SnapTrade via OAuth (env-level app configuration).
    true
  end
end
