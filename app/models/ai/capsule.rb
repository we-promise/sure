# Where AI calls may run: inside a job on one of the AI queues, which only the worker's AI
# capsules poll, so no model call holds a Puma thread or skips the queue that puts chat first.
#
# ApplicationJob marks a job as inside when its queue is an AI queue. The mark is fiber storage,
# like Ai::CallContext, so threads the job starts (Jev's parallel requests) inherit it.
#
# `check!` is for the transports: in development and test it raises when a call is made anywhere
# else. In production it does nothing, since a call that slipped through is slower, not wrong.
# Evals and the console opt out with `outside { }`.
module Ai::Capsule
  # A bug, not a model failure, so it isn't an Ai::Error that the plumbing rescues.
  class Violation < StandardError; end

  module_function

  def inside? = Fiber[:ai_capsule] == :inside

  # Marks the block as inside when `queue` is an AI queue.
  def within(queue, &block)
    Ai::Routes.ai_queues.include?(queue.to_s) ? mark(:inside, &block) : yield
  end

  # Passes `check!` without being inside, for code that calls a model deliberately outside a job.
  def outside(&block) = mark(:outside, &block)

  def check!
    return unless Rails.env.local?
    return if Fiber[:ai_capsule]

    raise Violation, "An AI call ran outside the AI capsule. Run it in a job on an AI queue (Ai::Routes.queue_for)."
  end

  def mark(state)
    previous = Fiber[:ai_capsule]
    Fiber[:ai_capsule] = state
    yield
  ensure
    Fiber[:ai_capsule] = previous
  end
  private_class_method :mark
end
