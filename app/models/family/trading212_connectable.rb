module Family::Trading212Connectable
  extend ActiveSupport::Concern

  included do
    has_many :trading212_items, dependent: :destroy
  end

  def can_connect_trading212?
    true
  end
end
