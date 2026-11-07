# RubyLLM's `config.instrumenter` on every context Sure builds (a public setting). RubyLLM runs
# each HTTP request inside `instrument("request.ruby_llm")`, so this is the one place every
# request passes, streamed or not: generations, probes, embeddings and a chat tool's nested call.
#
# It enforces the attempt budget: a request that would start after the call's deadline raises
# Ai::Error::Timeout instead of being sent.
#
# When a request fails, it puts the error, mapped and scrubbed by the transport, on the
# `request.ruby_llm` payload as `:ai_error` before the event finishes. RubyLLM has written the
# request's failed usage row by then, with no error, so UsageSubscriber adds this one to it and
# each retry's row shows its own cause.
class Ai::Transport::Instrumenter
  # map_error: turns a raised error into the Ai::Error the transport raises, scrubbed.
  def initialize(delegate = ActiveSupport::Notifications, map_error: ->(error) { error })
    @delegate = delegate
    @map_error = map_error
  end

  def instrument(name, payload = {}, &block)
    if name == "request.ruby_llm"
      check_budget!
      block = recording_failure(payload, block) if block
    end

    if @delegate
      @delegate.instrument(name, payload, &block)
    elsif block
      block.call(payload)
    end
  end

  private
    def recording_failure(payload, block)
      lambda do |event_payload|
        block.call(event_payload)
      rescue StandardError => error
        payload[:ai_error] = failure_details(error)
        raise
      end
    end

    def failure_details(error)
      mapped = @map_error.call(error) || error
      { error: mapped.message, error_class: mapped.class.name, http_status_code: mapped.try(:status) }.compact
    rescue StandardError
      nil
    end

    def check_budget!
      call = Ai::CallContext.current
      return unless call&.expired?

      raise Ai::Error::Timeout, "the attempt's time budget was spent before the request was sent"
    end
end
