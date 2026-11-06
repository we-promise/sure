# Who an AI call is for and what it belongs to, set around every transport call (section 10).
# It's a thin layer over RubyLLM's documented scopes, so RubyLLM's own events carry it:
#
# - `RubyLLM.with_usage_owner(family)`: `usage.ruby_llm` carries the family as `owner`;
# - `RubyLLM.workflow(name, id:, metadata:)`: every RubyLLM event carries `workflow_id` (the
#   call id), `workflow_parent_id` (the job's correlation id) and `workflow_metadata`.
#
# Sure keeps its own copy in fiber storage, which threads and fibers started inside inherit,
# so `.ai` events and the OpenTelemetry processor never read RubyLLM's internals. RubyLLM
# 2.1.1 keeps the workflow in Thread.current, which tool threads don't inherit; 2.2 moves it to
# fiber storage (#1327).
module Ai::CallContext
  CALL_KEY = :ai_call_context
  CORRELATION_KEY = :ai_correlation_id

  Call = Data.define(:feature, :call_id, :correlation_id, :family_id, :endpoint, :model, :deadline) do
    # Seconds left in the attempt budget, or nil when the call has none.
    def remaining = deadline && (deadline - Ai::CallContext.now)

    def expired? = !deadline.nil? && remaining <= 0

    def metadata = { feature:, call_id:, correlation_id:, family_id:, endpoint:, model: }.compact.transform_values(&:to_s)
  end

  module_function

  def current = Fiber[CALL_KEY]

  def correlation_id = Fiber[CORRELATION_KEY]

  # Around a job, with the correlation id from its arguments (sync_id, rule_run_id, chat_id,
  # pdf_import_id). Every call inside it is a child workflow of this one.
  def job(correlation_id)
    previous = Fiber[CORRELATION_KEY]
    Fiber[CORRELATION_KEY] = correlation_id.to_s
    RubyLLM.workflow("sure.job", id: correlation_id.to_s) { yield }
  ensure
    Fiber[CORRELATION_KEY] = previous
  end

  # Around one transport call. `budget` is the seconds one attempt may take, retries included.
  def call(feature:, model:, family: nil, budget: nil)
    call = Call.new(feature: feature.to_s, call_id: SecureRandom.uuid, correlation_id:, family_id: family&.id,
                    endpoint: model.endpoint.name, model: model.name, deadline: budget && now + budget)
    previous = Fiber[CALL_KEY]
    Fiber[CALL_KEY] = call

    RubyLLM.with_usage_owner(family) do
      RubyLLM.workflow("ai.#{call.feature}", id: call.call_id, metadata: call.metadata) { yield call }
    end
  ensure
    Fiber[CALL_KEY] = previous
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
