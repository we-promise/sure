class Assistant::Function
  class << self
    def name
      raise NotImplementedError, "Subclasses must implement the name class method"
    end

    def description
      raise NotImplementedError, "Subclasses must implement the description class method"
    end
  end

  MAX_PAGE_SIZE = 100

  def initialize(user)
    @user = user
  end

  def call(params = {})
    raise NotImplementedError, "Subclasses must implement the call method"
  end

  def name
    self.class.name
  end

  def description
    self.class.description
  end

  def params_schema
    build_schema
  end

  # (preferred) when in strict mode, the schema needs to include all properties in required array
  def strict_mode?
    true
  end

  def to_definition
    {
      name: name,
      description: description,
      params_schema: params_schema,
      strict: strict_mode?
    }
  end

  private
    attr_reader :user

    def build_schema(properties: {}, required: [])
      {
        type: "object",
        properties: prune_empty_enums(properties),
        required: required,
        additionalProperties: false
      }
    end

    # Enum values are built from user data (account names, tags, merchants, etc.)
    # and can be empty for a new family. An empty enum is invalid JSON Schema and
    # strict providers (e.g. xAI) reject the entire request, so drop the
    # constraint and fall back to a plain string.
    def prune_empty_enums(node)
      case node
      when Hash
        pruned = {}
        dropped_enum = false

        node.each do |key, value|
          # Enum members are literal values, not subschemas; keep them verbatim
          if key.to_sym == :enum && value.is_a?(Array)
            if value.empty?
              dropped_enum = true
            else
              pruned[key] = value
            end
            next
          end

          pruned[key] = prune_empty_enums(value)
        end

        if dropped_enum && !pruned.key?(:type) && !pruned.key?("type")
          pruned[:type] = "string"
        end

        pruned
      when Array
        node.map { |item| prune_empty_enums(item) }
      else
        node
      end
    end

    # Still used by update_tag, which identifies tags by name. Tag lists are
    # small; the large data-driven enums (accounts, categories, merchants)
    # are gone from schemas in favor of exact-name params.
    def family_tag_names
      @family_tag_names ||= family.tags.pluck(:name)
    end

    # Shared page-size clamp for paginated tools declaring a page_size param.
    def resolved_page_size(params)
      return self.class.default_page_size if params["page_size"].blank?

      params["page_size"].to_i.clamp(1, MAX_PAGE_SIZE)
    end

    # Pagy raises on zero, negative or non-numeric pages; normalize anything
    # invalid to the first page instead of failing the call.
    def resolved_page(params)
      page = params["page"].to_i
      page.positive? ? page : 1
    end

    def family
      user.family
    end

    def valid_uuid?(str)
      UuidFormat.valid?(str)
    end

    # To save tokens, we provide the AI metadata about the series and a flat
    # array of raw numeric values it can infer dates from. Currency is stated
    # once here instead of formatting every value; the system prompt's
    # formatting rules cover rendering. Values round to the currency's own
    # precision (BTC carries 8 decimals, OMR 3), never a flat 2.
    def to_ai_time_series(series)
      currency = series.values.first&.trend&.current&.currency
      precision = currency&.default_precision || 2

      {
        start_date: series.start_date,
        end_date: series.end_date,
        interval: series.interval,
        currency: currency&.iso_code,
        values: series.values.map { |v| v.trend.current.amount.round(precision).to_f }
      }.compact
    end
end
