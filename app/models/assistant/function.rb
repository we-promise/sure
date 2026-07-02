class Assistant::Function
  class << self
    def name
      raise NotImplementedError, "Subclasses must implement the name class method"
    end

    def description
      raise NotImplementedError, "Subclasses must implement the description class method"
    end
  end

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

  # Normalizes raw tool-call arguments so they match the declared params_schema
  # before the function runs.
  #
  # Some LLM / tool clients (notably local models served through Ollama) serialize
  # array arguments as JSON-encoded strings (e.g. "[\"Travel\"]") instead of real
  # JSON arrays. Without coercion these strings reach Array operations downstream
  # and blow up (e.g. `String#&`). See https://github.com/we-promise/sure/issues/1611.
  def coerce_arguments(raw_args)
    return raw_args unless raw_args.is_a?(Hash)

    keys = array_param_keys
    return raw_args if keys.empty?

    raw_args.each_with_object({}) do |(key, value), coerced|
      coerced[key] = keys.include?(key.to_s) ? coerce_to_array(value) : value
    end
  end

  private
    attr_reader :user

    # Names (as strings) of the params_schema properties declared as `type: "array"`.
    def array_param_keys
      properties = params_schema[:properties]
      return [] unless properties.is_a?(Hash)

      properties.filter_map do |key, definition|
        next unless definition.is_a?(Hash)

        type = definition[:type] || definition["type"]
        key.to_s if type.to_s == "array"
      end
    rescue StandardError => e
      Rails.logger.warn("#{self.class.name}#array_param_keys failed; skipping argument coercion: #{e.class} - #{e.message}")
      []
    end

    # Coerces a single value into an Array. Already-array and non-string values are
    # returned untouched; a JSON-array string is decoded; any other string is wrapped.
    def coerce_to_array(value)
      return value if value.is_a?(Array)
      return value unless value.is_a?(String)

      decoded =
        begin
          JSON.parse(value)
        rescue JSON::ParserError
          nil
        end

      decoded.is_a?(Array) ? decoded : [ value ]
    end

    def build_schema(properties: {}, required: [])
      {
        type: "object",
        properties: properties,
        required: required,
        additionalProperties: false
      }
    end

    def family_account_names
      @family_account_names ||= user.accessible_accounts.visible.pluck(:name)
    end

    def family_category_names
      @family_category_names ||= begin
        names = family.categories.pluck(:name)
        names << "Uncategorized"
        names
      end
    end

    def family_merchant_names
      @family_merchant_names ||= family.merchants.pluck(:name)
    end

    def family_tag_names
      @family_tag_names ||= family.tags.pluck(:name)
    end

    def family
      user.family
    end

    def valid_uuid?(str)
      UuidFormat.valid?(str)
    end

    # To save tokens, we provide the AI metadata about the series and a flat array of
    # raw, formatted values which it can infer dates from
    def to_ai_time_series(series)
      {
        start_date: series.start_date,
        end_date: series.end_date,
        interval: series.interval,
        values: series.values.map { |v| v.trend.current.format }
      }
    end
end
