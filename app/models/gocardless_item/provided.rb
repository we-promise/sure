module GocardlessItem::Provided
  extend ActiveSupport::Concern

  # Returns a Gocardless provider instance using GLOBAL credentials
  # Credentials are configured in /settings/providers (self-hosted) or ENV variables
  def gocardless_provider
    # Use the adapter's build_provider method which reads from global settings
    Provider::GocardlessAdapter.build_provider
  end
end
