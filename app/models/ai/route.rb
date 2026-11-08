# One entry in a feature's ordered model list: a model on an endpoint. The first entry is the
# normal choice; later ones are for failover and escalation.
#
# `condition` limits who an entry serves: a Jev entry serves only families that chose Jev
# (`:jev_family`).
#
# An entry's own settings, for that entry only:
# - prompt: the app/prompts folder it runs; nil means the feature's default;
# - json_mode: overrides the endpoint's;
# - reasoning_effort: one lowercase word sent as the model's effort; nil sends nothing (#3605).
Ai::Route = Data.define(:feature, :model, :condition, :prompt, :json_mode, :reasoning_effort) do
  def initialize(feature:, model:, condition: nil, prompt: nil, json_mode: nil, reasoning_effort: nil)
    json_mode = json_mode&.to_sym
    if json_mode && !Ai::Config::Endpoint::JSON_MODES.include?(json_mode)
      raise ArgumentError, "unknown JSON mode #{json_mode.inspect}"
    end
    if reasoning_effort && !reasoning_effort.to_s.match?(/\A[a-z]{1,16}\z/)
      raise ArgumentError, "reasoning effort must be one lowercase word"
    end

    super(feature: feature.to_sym, model:, condition:, prompt: prompt&.to_s, json_mode:,
          reasoning_effort: reasoning_effort&.to_s)
  end

  def endpoint = model.endpoint

  def effective_json_mode = json_mode || endpoint.json_mode

  # Jev and other decision models: they judge, they don't generate.
  def judge? = model.capable?(:judge)

  # The transport for this entry's endpoint.
  def transport = Ai::Transport.for(endpoint)

  # What instrumentation and Ai::Comparison record: endpoint, model and the entry's overrides.
  def to_event = model.to_event.merge({ prompt:, json_mode:, reasoning_effort: }.compact)

  def agent? = endpoint.agent?

  # A hash of needs (categorize) means a generation and a judgement: either set qualifies.
  def model_capable?(needs)
    needs.is_a?(Hash) ? needs.values.any? { model.capable?(_1) } : model.capable?(needs)
  end

  # An external assistant can be limited to some users' emails (EXTERNAL_ASSISTANT_ALLOWED_EMAILS).
  def serves_user?(user)
    allowed = Array(endpoint.agent_settings[:allowed_emails])
    return true if !agent? || allowed.empty?

    user&.email.present? && allowed.include?(user.email.downcase)
  end

  def serves?(family)
    case condition
    when nil then true
    when :jev_family then family.present? && family.effective_categorization_provider == "jev"
    else raise ArgumentError, "unknown route condition #{condition.inspect}"
    end
  end

  def inspect = "#<Ai::Route #{feature} #{endpoint.name}/#{model.name}>"
  alias_method :to_s, :inspect
end
