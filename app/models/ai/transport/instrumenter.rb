# RubyLLM's `config.instrumenter` on every context Sure builds. RubyLLM wraps each HTTP request
# in `instrument("request.ruby_llm")`, so every request passes here:
# - a request to a local endpoint holds a place at its host's gate (Ai::Gate) while it runs, and
#   the time it waited for one is added to the call's deadline;
# - a request that would start after the call's deadline isn't sent;
# - a failed request's mapped, scrubbed error goes on the payload as `:ai_error`, which
#   UsageSubscriber adds to that request's usage row.
class Ai::Transport::Instrumenter
  # map_error: turns a raised error into the Ai::Error the transport raises, scrubbed, or nil.
  # scrub: removes the endpoint's secrets from an error that has no Ai::Error.
  # endpoint: the endpoint the context sends to, for its gate.
  def initialize(delegate = ActiveSupport::Notifications, map_error: ->(error) { error }, scrub: ->(text) { text }, endpoint: nil)
    @delegate = delegate
    @map_error = map_error
    @scrub = scrub
    @endpoint = endpoint
  end

  def instrument(name, payload = {}, &block)
    return deliver(name, payload, &block) unless name == "request.ruby_llm"

    at_gate do
      # After the wait: a request that waited at the gate isn't charged for it.
      Ai::CallContext.check_budget!
      deliver(name, payload, &(block && recording_failure(payload, block)))
    end
  end

  private
    def deliver(name, payload, &block)
      if @delegate
        @delegate.instrument(name, payload, &block)
      elsif block
        block.call(payload)
      end
    end

    # The gate is looked up per request: contexts are cached per transport, and the gate's size
    # can change.
    def at_gate
      gate = @endpoint && Ai::Sequencer.gate_for(@endpoint)
      return yield unless gate

      gate.hold(Ai::Sequencer.lane, feature: Ai::CallContext.current&.feature, cancelled: Ai::Sequencer.cancelled) do |waited|
        Ai::CallContext.extend_deadline(waited)
        yield
      end
    end

    # An interrupted request's row is cancelled, not failed, so its error isn't recorded: it would
    # go on another request's failed row.
    def recording_failure(payload, block)
      lambda do |event_payload|
        block.call(event_payload)
      rescue StandardError => error
        payload[:ai_error] = failure_details(error) unless error.is_a?(Ai::Gate::Interrupted)
        raise
      end
    end

    def failure_details(error)
      mapped = @map_error.call(error)
      return { error: @scrub.call(error.message), error_class: error.class.name } if mapped.nil?

      { error: mapped.message, error_class: mapped.class.name, http_status_code: mapped.try(:status) }.compact
    rescue StandardError
      nil
    end
end
