module Family::StashawayConnectable
  extend ActiveSupport::Concern

  included do
    has_many :stashaway_items, dependent: :destroy
  end

  def can_connect_stashaway?
    true
  end
end
