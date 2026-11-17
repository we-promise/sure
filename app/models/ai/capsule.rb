# Where AI calls may run: inside a job on one of the AI queues, which only the worker's `ai`
# capsule polls, so no model call holds a Puma thread or skips the queue that puts chat first.
#
# ApplicationJob marks a job as inside when its queue is an AI queue. The mark lives in
# ActiveSupport::IsolatedExecutionState, so it covers the job's own thread (or fiber) and not
# threads the job starts.
#
# `check!` raises in development and test when a call is made anywhere else; in production it
# does nothing, since a call that slipped through is slower, not wrong. The evals and the console
# opt out with `outside { }`, which the Sure/AiOutsideCapsule cop limits to the evals.
module Ai::Capsule
  # A bug, not a model failure, so it isn't an Ai::Error that the plumbing rescues.
  class Violation < StandardError; end

  STATE_KEY = :ai_capsule
  QUEUES = Ai::Routes.ai_queues

  module_function

  def inside? = ActiveSupport::IsolatedExecutionState[STATE_KEY] == :inside

  # Runs the block as a job on `queue`: inside when the queue is an AI queue.
  def within(queue, &block)
    QUEUES.include?(queue.to_s) ? mark(:inside, &block) : yield
  end

  # Runs the block as if inside, for code that calls a model deliberately outside a job.
  def outside(&block) = mark(:outside, &block)

  def check!
    return unless Rails.env.local?
    return if ActiveSupport::IsolatedExecutionState[STATE_KEY]

    raise Violation, "An AI call ran outside the AI capsule. Run it in a job on an AI queue (Ai::Routes.queue_for)."
  end

  def mark(state)
    previous = ActiveSupport::IsolatedExecutionState[STATE_KEY]
    ActiveSupport::IsolatedExecutionState[STATE_KEY] = state
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[STATE_KEY] = previous
  end
  private_class_method :mark
end
