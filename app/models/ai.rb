# The AI layer's façade. Ask it whether a feature can run
# instead of looking for a provider:
#
#   Ai.available?(:enhance_merchants, family: Current.family, user: Current.user)
#   Ai.availability(:bill_setup, family:, user:).message_for(user)
#
# Feature keys are listed in Ai::Routes::MATRIX. See docs/llm-guides/ai-pipeline.md.
module Ai
  module_function

  def available?(feature, family:, user: nil) = availability(feature, family:, user:).available?

  # @return [Ai::Availability]
  def availability(feature, family:, user: nil)
    result = Ai::Router.new(family:, user:).resolve(feature)
    result.is_a?(Ai::Plan) ? Ai::Availability.available(feature) : result
  end

  # @return [Ai::Plan, nil] the routes this family and user may use, or nil when none
  def plan(feature, family:, user: nil)
    result = Ai::Router.new(family:, user:).resolve(feature)
    result if result.is_a?(Ai::Plan)
  end
end
