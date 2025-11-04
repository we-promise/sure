module LunchflowItem::Provided
  extend ActiveSupport::Concern

  def lunchflow_provider
    Provider::LunchflowAdapter.build_provider
  end
end
