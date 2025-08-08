module SimplefinItem::Provided
  extend ActiveSupport::Concern

  def simplefin_provider
    @simplefin_provider ||= Provider::Simplefin.new
  end
end
