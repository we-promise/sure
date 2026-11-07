# THE resolution path (section 5.3): for this feature, family and user, what may run, and if
# nothing may, why. Every feature asks it, through Ai.available? and Ai.availability, instead of
# looking for a provider itself.
#
# It reads only Ai::Config, Ai::Routes and Ai::Consent, and never looks at liveness: down
# endpoints are the caller's concern at run time (2c), so availability doesn't flicker. PR 7 adds
# the family's consent to Ai::Consent; PR 9 adds the family's allowed endpoints and own keys here.
class Ai::Router
  def initialize(family:, user: nil, config: Ai::Config.current)
    @family, @user, @config = family, user, config
  end

  # @return [Ai::Plan, Ai::Availability] a plan, or an unavailable availability with its reason
  def resolve(feature)
    feature = feature.to_sym
    spec = Ai::Routes.fetch(feature)
    listed = @config.routes_for(spec[:route_of] || feature)
                    .select { |route| route.agent? == agent_chat?(feature) && route.serves_user?(@user) && route.serves?(@family) }
    return Ai::Availability.unavailable(feature, :not_configured) if listed.empty?   # first: nothing to consent to

    if (reason = Ai::Consent.denial(feature, family: @family, user: @user))
      return Ai::Availability.unavailable(feature, reason)
    end

    capable = listed.select { |route| route.agent? || route.model_capable?(Ai::Routes.needs_for(feature)) }
    return Ai::Availability.unavailable(feature, :capability_missing) if capable.empty?

    Ai::Plan.new(feature:, lane: spec[:lane], routes: capable)
  end

  private
    # An agent endpoint serves chat for families whose chat mode is external, and nothing else.
    def agent_chat?(feature) = feature == :chat && @family&.chat_mode_external? || false
end
