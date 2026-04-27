module GocardlessConnectable
  extend ActiveSupport::Concern

  included do
    has_many :gocardless_items, dependent: :destroy
  end

  def can_connect_gocardless?
    true
  end
end