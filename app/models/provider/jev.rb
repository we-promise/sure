class Provider::Jev < Provider
  include ClassificationConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Jev::Error
  Error = Class.new(Provider::Error)

  # Defaults to TypeSafe's own API rather than a reseller. Gateways like
  # OpenRouter serve the identical payload and answer types, so one class covers
  # both — but routing a family's transaction descriptions through an extra
  # party should be something an operator opts into, not something they inherit
  # from a default. For OpenRouter, set JEV_ENDPOINT to
  # https://openrouter.ai/api/alpha/decisions and JEV_MODEL to
  # ~typesafe/jev-latest.
  DEFAULT_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
  DEFAULT_MODEL = "jev-latest"

  # The vendor's own host. Anything else is reached through a gateway, which the
  # data-sharing disclosure has to name — telling someone their bank
  # descriptions go to TypeSafe is wrong when they transit a proxy first.
  VENDOR_HOST = "api.typesafe.ai"

  # Hosts where plaintext carries no network exposure. See .endpoint_allowed?.
  # Matched against URI#hostname, which unwraps the brackets URI#host keeps on
  # an IPv6 literal, so "::1" is the only spelling needed.
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  # Documented API limits.
  MAX_CHOICE_OPTIONS = 255
  SCORE_LEVELS = (2..10)

  QUESTION_TYPES = %w[choice score noul].freeze

  # Offered alongside the real categories so the model has somewhere to put a
  # transaction that fits none of them. Choice always returns one of the keys it
  # was given, so without an explicit opt-out it would be forced to guess.
  # Verified: an opaque "ACH DEBIT 4471920 REF#88213" descriptor selects
  # UNCATEGORIZED at probability 1.0.
  UNCATEGORIZED = "__uncategorized__"

  CATEGORY_INSTRUCTIONS = "Which spending category best fits this bank transaction? " \
                          "Pick `#{UNCATEGORIZED}` only if no category is a reasonable fit.".freeze

  # Jev takes one state per request, so a batch of transactions is a batch of
  # requests. They are independent and latency-bound (~400-550ms each), so they
  # run concurrently.
  DEFAULT_CONCURRENCY = 8

  class << self
    def configured?
      api_key.present?
    end

    # Deliberately does not fall back to OPENROUTER_API_KEY. A self-hoster with
    # an OpenRouter key set for some unrelated purpose would otherwise find Jev
    # silently enabled and paying for classification they never opted into.
    # Enabling this provider has to be an explicit act.
    def api_key
      ENV["JEV_API_KEY"].presence || Setting.jev_api_key
    end

    def effective_model
      (ENV["JEV_MODEL"].presence || Setting.jev_model).presence || DEFAULT_MODEL
    end

    def effective_endpoint
      (ENV["JEV_ENDPOINT"].presence || Setting.jev_endpoint).presence || DEFAULT_ENDPOINT
    end

    # Every request carries a Bearer token in the headers and the family's
    # transaction descriptions in the body, so an http:// endpoint discloses
    # both in cleartext — a credential leak, not merely a downgrade.
    #
    # The scheme has to be named explicitly: URI::HTTPS subclasses URI::HTTP,
    # so the obvious `is_a?(URI::HTTP)` check silently accepts http://.
    #
    # Loopback is exempt. An operator running a gateway on the same host has no
    # network segment to intercept, and demanding a valid certificate for
    # 127.0.0.1 would push them towards disabling verification altogether,
    # which is worse than the thing this guards against.
    def endpoint_allowed?(url)
      uri = URI.parse(url.to_s)
      return false unless uri.is_a?(URI::HTTP) && uri.host.present?
      return true if uri.scheme == "https"

      uri.scheme == "http" && LOOPBACK_HOSTS.include?(uri.hostname.to_s.downcase)
    rescue URI::InvalidURIError
      false
    end
  end

  def initialize(api_key, endpoint: nil, model: nil, concurrency: nil)
    @api_key = api_key # pipelock:ignore
    @endpoint = endpoint.presence || DEFAULT_ENDPOINT

    # Enforced here as well as in the settings form so that JEV_ENDPOINT and
    # eval-time construction, which never touch the form, get the same check.
    unless self.class.endpoint_allowed?(@endpoint)
      raise Error, "Jev endpoint must use https (or http on loopback): #{@endpoint}"
    end

    @default_model = model.presence || DEFAULT_MODEL
    @concurrency = (concurrency || ENV["JEV_CONCURRENCY"]).to_i
    @concurrency = DEFAULT_CONCURRENCY unless @concurrency.positive?
  end

  def provider_name
    proxied? ? "Jev via #{endpoint_host}" : "Jev"
  end

  # True when requests reach TypeSafe through a gateway rather than directly.
  def proxied?
    endpoint_host != VENDOR_HOST
  end

  def endpoint_host
    self.class.host_for(@endpoint)
  end

  class << self
    def host_for(endpoint)
      URI.parse(endpoint.to_s).host.presence || endpoint.to_s
    rescue URI::InvalidURIError
      endpoint.to_s
    end

    # The host an operator's current configuration will actually send to, for
    # the settings disclosure.
    def effective_host
      host_for(effective_endpoint)
    end

    def effective_proxied?
      effective_host != VENDOR_HOST
    end
  end

  def decide(state:, questions:, model: "", family: nil)
    with_provider_response do
      decide!(state: state, questions: questions, model: model)
    end
  end

  # Mirrors Provider::LlmConcept#auto_categorize's signature so the existing
  # categorization eval runner and Family::AutoCategorizer consume this provider
  # without changes. `json_mode` is accepted and ignored: Jev's output is typed
  # at the protocol level, so there is no JSON parsing to coerce.
  def auto_categorize(transactions: [], user_categories: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      if user_categories.blank?
        Rails.logger.error("Cannot auto-categorize transactions for family #{family&.id || 'unknown'}: no categories available")
        raise Error, "No categories available for auto-categorization"
      end

      criteria = category_criteria(user_categories)
      effective_model = model.presence || @default_model

      in_parallel(transactions) do |transaction|
        categorize_one(transaction, criteria: criteria, model: effective_model)
      end.compact
    end
  end

  private
    attr_reader :api_key

    def categorize_one(transaction, criteria:, model:)
      question = {
        type: "choice",
        instructions: CATEGORY_INSTRUCTIONS,
        criteria: criteria
      }

      result = decide!(
        state: transaction_state(transaction),
        questions: { category: question },
        model: model
      )

      decision = result[:category]
      return nil unless decision

      ClassificationConcept::CategoryDecision.new(
        transaction_id: transaction[:id],
        category_name: choice_or_nil(decision.value),
        confidence: decision.confidence,
        probabilities: decision.probabilities,
        usage: result.usage
      )
    end

    # A Choice always returns one of its keys, so the opt-out sentinel is how
    # "none of these" comes back. Translate it to nil at the boundary.
    def choice_or_nil(value)
      return nil if value.nil? || value == UNCATEGORIZED

      value
    end

    # Categories carry no description column, so the criteria hint is derived
    # from the hierarchy. A nil value is valid and means "the name speaks for
    # itself".
    def category_criteria(user_categories)
      if user_categories.size >= MAX_CHOICE_OPTIONS
        raise Error, "Too many categories for one Choice question. Max is #{MAX_CHOICE_OPTIONS - 1} plus the opt-out."
      end

      by_id = user_categories.index_by { |category| category[:id].to_s }

      criteria = user_categories.each_with_object({}) do |category, acc|
        parent = by_id[category[:parent_id].to_s]
        acc[category[:name].to_s] = parent ? "Subcategory of #{parent[:name]}" : nil
      end

      criteria[UNCATEGORIZED] = "No listed category is a reasonable fit"
      criteria
    end

    def transaction_state(transaction)
      {
        description: transaction[:description],
        amount: transaction[:amount],
        classification: transaction[:classification],
        merchant: transaction[:merchant],
        hint: transaction[:hint]
      }.compact
    end

    def decide!(state:, questions:, model: "")
      raise Error, "No questions provided" if questions.blank?

      questions = questions.transform_keys(&:to_s)
      questions.each { |key, question| validate_question!(key, question) }

      response = client.post(@endpoint) do |req|
        req.body = {
          model: model.presence || @default_model,
          state: state,
          questions: questions
        }
      end

      parse_decision_set(JSON.parse(response.body))
    end

    def validate_question!(key, question)
      type = (question[:type] || question["type"]).to_s
      unless QUESTION_TYPES.include?(type)
        raise Error, "Question '#{key}' has unknown type #{type.inspect}; expected one of #{QUESTION_TYPES.join(', ')}"
      end

      criteria = question[:criteria] || question["criteria"]

      case type
      when "choice"
        if criteria.to_h.size > MAX_CHOICE_OPTIONS
          raise Error, "Question '#{key}' has #{criteria.size} options; max is #{MAX_CHOICE_OPTIONS}"
        end
      when "score"
        unless SCORE_LEVELS.cover?(criteria.to_a.size)
          raise Error, "Question '#{key}' has #{criteria.to_a.size} rubric levels; must be #{SCORE_LEVELS.min}-#{SCORE_LEVELS.max}"
        end
      end
    end

    def parse_decision_set(body)
      answers = body["answers"]
      raise Error, "Malformed Jev response: missing 'answers'" unless answers.is_a?(Hash)

      decisions = answers.each_with_object({}) do |(key, answer), acc|
        acc[key] = build_decision(key, answer)
      end

      ClassificationConcept::DecisionSet.new(
        decisions: decisions,
        model: body["model"],
        usage: build_usage(body["usage"])
      )
    end

    def build_decision(key, answer)
      type = answer["type"].to_s

      value = case type
      when "choice" then answer["choice"]
      when "score"  then answer["score"]
      when "noul"   then answer["noul"]
      else raise Error, "Unknown answer type #{type.inspect} for question '#{key}'"
      end

      ClassificationConcept::Decision.new(
        key: key,
        type: type,
        value: value,
        probabilities: answer["probabilities"],
        confidence: confidence_for(type, value, answer["confidence"])
      )
    end

    # Derived per type rather than with a general fallback. noul_confidence is
    # (value - 0.5).abs * 2, which is only meaningful for a noul: applied to a
    # score it produces values outside 0..1 (a score of 1.92 yields 2.84), and
    # applied to a choice it returns nil because the value is a String.
    #
    # A choice or score arriving without a confidence is a malformed response.
    # It reports 0 rather than nil so a downstream threshold reads it as
    # maximally unconfident and withholds, instead of mistaking it for a
    # provider that does not do confidence at all and waving it through.
    # Clamped because the gate that consumes this compares against a threshold
    # constrained to 0..1: an out-of-range confidence (a reported 1.5, or a
    # noul_confidence derived from a probability outside 0..1) would clear every
    # threshold and be applied and locked, which is the precise outcome the
    # withholding logic exists to prevent. A malformed answer must fail closed.
    def confidence_for(type, value, reported)
      return reported.to_f.clamp(0.0, 1.0) if reported
      return noul_confidence(value) if type == "noul"

      0.0
    end

    # Noul answers carry no confidence field — the probability is the answer.
    # Distance from 0.5 is the equivalent signal: 0.5 is maximal uncertainty,
    # 0.0 and 1.0 are maximal certainty.
    #
    # Bounded here rather than in the caller because this is the expression that
    # can exceed 1, and because a nil must survive: it means "not a number at
    # all", which the withholding gate reads as zero and refuses, whereas
    # clamping a nil would raise on the one input worth sanitizing.
    def noul_confidence(value)
      return nil unless value.is_a?(Numeric)

      ((value - 0.5).abs * 2).clamp(0.0, 1.0)
    end

    def build_usage(usage)
      return {} unless usage.is_a?(Hash)

      {
        "input_tokens" => usage["input_tokens"].to_i,
        "output_tokens" => usage["output_tokens"].to_i,
        "total_tokens" => usage["input_tokens"].to_i + usage["output_tokens"].to_i,
        # OpenRouter reports settled cost per call; TypeSafe's native API does
        # not, so this is absent when talking to TypeSafe directly.
        "cost" => usage["cost"]
      }.compact
    end

    # Fixed pool over a work queue. Thread#join re-raises worker exceptions, so
    # a failed request still surfaces through with_provider_response.
    #
    # The executor wrap is defensive: nothing in here touches ActiveRecord
    # today, but these threads run inside a Sidekiq worker, and an unwrapped
    # thread that later grows a query would check out a connection and never
    # return it.
    # Matches the fan-out idiom in Security::Provided — total wall time is
    # max(request latencies) rather than sum. Unlike that one it runs on a
    # bounded pool: this fans out per transaction, so an unbounded
    # Promises.future would open a socket for every row in the batch.
    #
    # `value!` re-raises a worker's exception, so a failed request still
    # surfaces through with_provider_response rather than landing as a nil.
    def in_parallel(items)
      items = items.to_a
      return [] if items.empty?

      pool = Concurrent::FixedThreadPool.new([ @concurrency, items.size ].min)

      begin
        items
          .map { |item| Concurrent::Promises.future_on(pool) { Rails.application.executor.wrap { yield(item) } } }
          .map(&:value!)
      ensure
        pool.shutdown
        pool.wait_for_termination
      end
    end

    def client
      @client ||= Faraday.new(ssl: self.class.faraday_ssl_options) do |faraday|
        # Two defaults have to be overridden for this backoff to run at all.
        # faraday-retry only retries IDEMPOTENT_METHODS, which excludes POST;
        # opting POST in is safe here because a decision request has no side
        # effects. And `retry_statuses` is never consulted, because the
        # `raise_error` handler below converts the status into an exception
        # first — so the throttle and overload signals the API documents (429
        # and 529) have to be named as exception classes instead.
        faraday.request(:retry, {
          max: 3,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2,
          methods: [ :post ],
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [
            Faraday::ConnectionFailed,
            Faraday::TooManyRequestsError,
            Faraday::ServerError
          ]
        })
        faraday.request :json
        faraday.response :raise_error
        faraday.options.timeout = ENV.fetch("JEV_REQUEST_TIMEOUT", 30).to_i
        faraday.options.open_timeout = 5
        faraday.headers["Authorization"] = "Bearer #{api_key}"
        faraday.headers["Accept"] = "application/json"
      end
    end
end
