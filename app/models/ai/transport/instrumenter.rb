# RubyLLM's `config.instrumenter` on every context Sure builds. RubyLLM wraps each HTTP request
# in `instrument("request.ruby_llm")`, so every request passes here: a request that would start
# after the call's deadline isn't sent, and a failed request's mapped, scrubbed error goes on the
# payload as `:ai_error`, which UsageSubscriber adds to that request's usage row.
class Ai::Transport::Instrumenter
  # map_error: turns a raised error into the Ai::Error the transport raises, scrubbed, or nil.
  # scrub: removes the endpoint's secrets from an error that has no Ai::Error.
  def initialize(delegate = ActiveSupport::Notifications, map_error: ->(error) { error }, scrub: ->(text) { text })
    @delegate = delegate
    @map_error = map_error
    @scrub = scrub
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
      mapped = @map_error.call(error)
      return { error: @scrub.call(error.message), error_class: error.class.name } if mapped.nil?

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
