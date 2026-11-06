# RubyLLM's `config.instrumenter` on every context Sure builds (a public setting). RubyLLM runs
# each HTTP request inside `instrument("request.ruby_llm")`, so this is the one place every
# request passes, streamed or not: generations, probes, embeddings and a chat tool's nested call.
#
# In 2a it enforces the attempt budget: a request that would start after the call's deadline
# raises Ai::Error::Timeout instead of being sent. PR 4 adds the host's gate here (section 11).
class Ai::Transport::Instrumenter
  def initialize(delegate = ActiveSupport::Notifications)
    @delegate = delegate
  end

  def instrument(name, payload = {}, &block)
    check_budget! if name == "request.ruby_llm"

    if @delegate
      @delegate.instrument(name, payload, &block)
    elsif block
      block.call(payload)
    end
  end

  private
    def check_budget!
      call = Ai::CallContext.current
      return unless call&.expired?

      raise Ai::Error::Timeout, "the attempt's time budget was spent before the request was sent"
    end
end
