module StashawayItem::Provided
  extend ActiveSupport::Concern

  def stashaway_provider
    raise Provider::Stashaway::AuthenticationError, "StashAway is not signed in" unless credentials_configured?

    stashaway_client(token: api_token)
  end

  def stashaway_client(token: nil)
    Provider::Stashaway.new(region: region, token: token)
  end
end
