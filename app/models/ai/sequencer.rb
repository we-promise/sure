# The lane an AI call runs in: interactive, prompt or background (Ai::Routes::MATRIX). A job takes
# its queue's lane (ApplicationJob); evals and the console choose one with `with_lane`.
#
# The lane is fiber storage, like Ai::CallContext and Ai::Capsule's mark, so threads a job starts
# (Jev's parallel requests) run in the job's lane.
module Ai::Sequencer
  LANES = %i[interactive prompt background].freeze

  module_function

  # A call outside any lane (a test, the console) counts as interactive, so nothing makes it wait
  # for work that would never come back for it.
  def lane = Fiber[:ai_lane] || :interactive

  # Runs the block in `lane`; nil leaves the current lane as it is.
  def with_lane(lane)
    return yield if lane.nil?
    raise ArgumentError, "unknown lane: #{lane.inspect}" unless LANES.include?(lane)

    begin
      previous = Fiber[:ai_lane]
      Fiber[:ai_lane] = lane
      yield
    ensure
      Fiber[:ai_lane] = previous
    end
  end
end
