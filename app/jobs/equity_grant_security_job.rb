# Finds the security for a grant's ticker and fetches its latest price, so the
# grants tab can value the grant without calling a provider while rendering.
class EquityGrantSecurityJob < ApplicationJob
  queue_as :low_priority

  def perform(grant)
    grant.resolve_security!
  end
end
