# The AI layer's error taxonomy.
# Transports map client-library and HTTP errors onto these classes, so code above a transport
# never rescues a provider's own errors.
module Ai::Error
  class Base < StandardError
    attr_reader :status

    def initialize(message = nil, status: nil)
      @status = status
      super(message)
    end
  end

  # Raised by `call!` on a feature that resolves unavailable.
  class Unavailable < Base
    attr_reader :reason, :code

    def initialize(reason, code: nil)
      @reason = reason
      @code = code
      super("AI unavailable: #{reason}")
    end
  end

  Cancelled      = Class.new(Base)
  Unreachable    = Class.new(Base)   # connection refused, DNS, TLS: no response came back
  Timeout        = Class.new(Base)
  RateLimited    = Class.new(Base)   # 429
  Upstream       = Class.new(Base)   # 5xx
  Unauthorized   = Class.new(Base)   # 401/403: the key is wrong
  NoCredit       = Class.new(Base)   # the key's balance is spent
  ModelMissing   = Class.new(Base)   # the endpoint doesn't have the model
  ContextTooLong = Class.new(Base)   # 400 saying the input is too long
  InvalidOutput  = Class.new(Base)   # parse or schema failure after the transport's fallbacks
  OutputCut      = Class.new(ContextTooLong)   # the answer stopped at the output limit: split the batch
  Refused        = Class.new(Base)   # any other 4xx: not retried anywhere
  # The model can't take this input (an image to a model without vision): the next route may.
  UnsupportedInput = Class.new(Refused)

  # Errors a transport retries itself, up to the endpoint's max_retries.
  RETRYABLE = [ RateLimited, Upstream, Timeout ].freeze

  # Each provider words these differently.
  CONTEXT_TOO_LONG = [
    /context length/i, /context window/i, /context size/i, /maximum context/i, /context limit/i,
    /too many tokens/i, /prompt is too long/i, /input is too long/i, /reduce the length/i,
    /exceeds the available context/i
  ].freeze

  # Anthropic: 400 "credit balance is too low". OpenAI: 429 insufficient_quota or
  # credit_balance_exhausted ("You have no credits remaining."). OpenRouter: 402.
  NO_CREDIT = [
    /credit balance is too low/i, /insufficient_quota/i, /credit_balance_exhausted/i,
    /no credits remaining/i, /insufficient credits/i, /exceeded your current quota/i
  ].freeze

  # Ollama: 404 "model 'x' not found". OpenAI: 404 model_not_found, "The model `x` does not exist".
  MODEL_MISSING = [ /model_not_found/i, /model\b.{0,120}\bnot found/im, /model\b.{0,120}\bdoes not exist/im ].freeze

  # llama.cpp and Ollama: 500 "image input is not supported" from a model without a vision
  # projector. The model can't do it, so it's a refusal, not an outage to retry or mark down; the
  # next route is still tried (Ai::Generation), as it may have vision.
  UNSUPPORTED_INPUT = [ /image input is not supported/i ].freeze

  module_function

  def for_status(status, message = nil, body: nil)
    text = [ message, body.is_a?(String) ? body : body&.to_json ].compact.join(" ")

    case status.to_i
    when 401, 403 then Unauthorized
    when 402 then NoCredit
    when 404 then matches?(text, MODEL_MISSING) ? ModelMissing : Refused
    when 408 then Timeout
    when 429 then matches?(text, NO_CREDIT) ? NoCredit : RateLimited
    when 400, 413
      if matches?(text, CONTEXT_TOO_LONG) then ContextTooLong
      elsif matches?(text, NO_CREDIT) then NoCredit
      else Refused
      end
    when 500..599
      # Only the provider's own message says the model refused an image. A client gem's
      # `message`, and a gateway's other fields, can quote an earlier refusal from a diagnostic;
      # neither may turn a retryable 503 into a refusal.
      message_text = provider_message(body) || (body.nil? ? message : nil)
      matches?(message_text.to_s, UNSUPPORTED_INPUT) ? UnsupportedInput : Upstream
    else Refused
    end
  end

  def from_status(status, message = nil, body: nil)
    for_status(status, message, body:).new(message, status: status.to_i)
  end

  # Maps an error from Faraday, Net::HTTP or a client gem that exposes an HTTP status onto the
  # taxonomy. Returns nil for an error it doesn't recognise, so the caller decides.
  def from_exception(error)
    case error
    when Base then error
    when Faraday::TimeoutError, ::Timeout::Error, Net::ReadTimeout, Net::OpenTimeout
      Timeout.new(error.message)
    when Faraday::ConnectionFailed, Faraday::SSLError, SocketError, Errno::ECONNREFUSED,
         Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET, OpenSSL::SSL::SSLError
      Unreachable.new(error.message)
    when Faraday::ParsingError
      # A body that isn't JSON. Its status is often 200, which from_status would call a refusal.
      InvalidOutput.new(error.message)
    else
      status, body = status_and_body(error)
      from_status(status, error.message, body:) if status
    end
  end

  # ruby-openai raises Faraday errors whose response is a Hash; the anthropic gem's errors
  # carry `status` and `body`.
  def status_and_body(error)
    response = error.respond_to?(:response) ? error.response : nil
    if response.is_a?(Hash)
      [ response[:status] || response["status"], response[:body] || response["body"] ]
    elsif response.respond_to?(:status)
      [ response.status, response.respond_to?(:body) ? response.body : nil ]
    elsif error.respond_to?(:status) && error.status.is_a?(Integer)
      [ error.status, error.respond_to?(:body) ? error.body : nil ]
    end
  end

  def matches?(text, patterns) = patterns.any? { text.match?(_1) }

  # The provider's `error.message`, when the body is a JSON object. Not the whole body: a
  # gateway may put an earlier provider message in another field as a diagnostic.
  def provider_message(body)
    parsed = body.is_a?(String) ? (JSON.parse(body) rescue nil) : body
    error = parsed.is_a?(Hash) ? parsed["error"] || parsed[:error] : nil
    case error
    when Hash then error["message"] || error[:message]
    when String then error
    end
  end
  private_class_method :status_and_body, :matches?, :provider_message
end
