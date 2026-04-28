module GocardlessItem::Provided
  extend ActiveSupport::Concern

  def gocardless_provider
    Provider::GocardlessAdapter.build_provider(family: family)
  end
end