module Family::LunchflowConnectable
  extend ActiveSupport::Concern

  included do
    has_many :lunchflow_items, dependent: :destroy
  end

  def can_connect_lunchflow?
    # Check if the API key is configured
    Provider::LunchflowAdapter.configured?
  end
end
