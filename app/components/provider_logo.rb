# Renders a sync provider's own logo, falling back in order:
#   1. the provider's brand icon from Brandfetch (needs a domain and a client ID)
#   2. the provider's generic icon (`logo_icon`), for providers with no brand
#   3. the provider's initials (`logo_text`)
#
# The fallback is always rendered and the Brandfetch image is laid over it on an
# opaque background. Brandfetch is asked for a 404 rather than its lettermark
# when it doesn't know the brand, and a failed image removes itself to reveal
# the fallback.
class ProviderLogo < ApplicationComponent
  REMOVE_ON_ERROR = "this.remove()".freeze

  def initialize(provider_key:, class_name: "w-8 h-8 rounded-full")
    @provider_key = provider_key
    @class_name = class_name
  end

  attr_reader :class_name

  def brand_url
    Provider::Metadata.logo_url(@provider_key)
  end

  def metadata
    @metadata ||= Provider::Metadata.for(@provider_key)
  end

  def fallback_icon
    metadata[:logo_icon]
  end

  def fallback_text
    metadata[:logo_text]
  end

  def fallback_color
    metadata[:logo_color]
  end

  def rounded?
    class_name.to_s.include?("rounded-full")
  end
end
