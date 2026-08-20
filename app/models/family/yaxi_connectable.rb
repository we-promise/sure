module Family::YaxiConnectable
  extend ActiveSupport::Concern

  included do
    has_many :yaxi_items, dependent: :destroy
    has_many :yaxi_tickets, dependent: :destroy
  end
end
