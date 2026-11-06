# The base class of a feature answered by a decision model (Jev, section 8): typed questions about
# each item instead of a prompt and a schema. A judgement is the other half of a generation that
# declares `judged_by`: Ai::Generation's loop builds it on a `judge` route, with the same slice of
# items, so batching, failover and down marks stay in one place, and failover from a judge model
# to an LLM switches class. It returns the generation's value shape, so the requester sees one.
#
# A subclass takes the generation's arguments and defines:
#   questions          -> { name => { type:, instructions:, options: } }, plain data (no Procs)
#   states             -> { item id => the Hash the model judges }
#   value_from(answers) -> the generation's value, from { item id => { name => answer } | nil }
class Ai::Judgement
  class_attribute :feature_key, instance_writer: false

  def self.feature(key) = self.feature_key = key.to_sym

  attr_reader :family

  def initialize(family:)
    @family = family
  end

  def questions = raise(NotImplementedError)
  def states = raise(NotImplementedError)
  def value_from(answers) = raise(NotImplementedError)

  # Judges every item on `route` and returns [value, usage].
  def run(route)
    request = Ai::Transport::Base::JudgeRequest.new(feature: feature_key, family:, model: route.model, states:, questions:)
    response = route.transport.judge(request)
    [ value_from(response.answers), response.usage ]
  end
end
