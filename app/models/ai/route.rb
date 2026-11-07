# One entry in a feature's ordered model list (section 5.2): a model on an endpoint. The first
# entry is the normal choice; later ones are for failover and escalation (2c).
#
# `condition` limits who an entry serves. Until 2d, a Jev entry serves only families that chose
# Jev (`:jev_family`), which is today's rule; 2d deletes it with `families.categorization_provider`.
Ai::Route = Data.define(:feature, :position, :model, :condition) do
  def initialize(feature:, position:, model:, condition: nil)
    super(feature: feature.to_sym, position:, model:, condition:)
  end

  def endpoint = model.endpoint

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

  def inspect = "#<Ai::Route #{feature}[#{position}] #{endpoint.name}/#{model.name}>"
  alias_method :to_s, :inspect
end
