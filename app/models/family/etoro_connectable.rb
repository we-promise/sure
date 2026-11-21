module Family::EtoroConnectable
  extend ActiveSupport::Concern

  included do
    has_many :etoro_items, dependent: :destroy
  end

  def can_connect_etoro?
    true
  end
end
