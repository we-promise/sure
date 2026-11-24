module Family::TinkoffInvestConnectable
  extend ActiveSupport::Concern

  included do
    has_many :tinkoff_invest_items, dependent: :destroy
  end

  def can_connect_tinkoff_invest?
    true
  end
end
