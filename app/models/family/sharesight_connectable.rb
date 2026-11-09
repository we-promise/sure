module Family::SharesightConnectable
  extend ActiveSupport::Concern

  included do
    has_many :sharesight_items, dependent: :destroy
  end

  def can_connect_sharesight?
    true
  end
end
