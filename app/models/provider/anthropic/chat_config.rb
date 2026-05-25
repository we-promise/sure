class Provider::Anthropic::ChatConfig
  def initialize(
    prompt:,
    instructions: nil,
    functions: [],
    function_results: [],
    conversation_history: [],
    default_max_tokens: 4096
  )
    @prompt = prompt
    @instructions = instructions
    @functions = functions
    @function_results = function_results
    @conversation_history = conversation_history
    @default_max_tokens = default_max_tokens
  end

  def build_request(model:)
    params = {
      model: model,
      max_tokens: @default_max_tokens,
      messages: build_messages
    }

    system_blocks = build_system_blocks
    params[:system_] = system_blocks if system_blocks.present?

    tool_blocks = build_tools
    params[:tools] = tool_blocks if tool_blocks.present?

    params
  end

  private
    def build_messages
      Provider::Anthropic::MessageFormatter.new(
        prompt: @prompt,
        conversation_history: @conversation_history,
        function_results: @function_results
      ).build
    end

    def build_system_blocks
      return nil if @instructions.blank?

      # System prompts are cached aggressively — they rarely change within a session
      # and re-using them via prompt caching cuts input cost ~10x on cache hits.
      [
        {
          type: "text",
          text: @instructions,
          cache_control: { type: "ephemeral" }
        }
      ]
    end

    def build_tools
      return [] if @functions.blank?

      tools = @functions.map do |fn|
        {
          name: fn[:name],
          description: fn[:description],
          input_schema: anthropic_input_schema(fn[:params_schema])
        }
      end

      # Cache tool definitions alongside the system prompt: same TTL behaviour and
      # they almost never change between turns.
      tools.last[:cache_control] = { type: "ephemeral" } if tools.any?

      tools
    end

    # OpenAI strict schemas frequently include `additionalProperties: false`, which
    # Anthropic also accepts. The shapes are otherwise JSON Schema 2020-12 compatible.
    # `strict` is OpenAI-only and must not be forwarded — strip both symbol and
    # string keys so we don't leak it when a caller hands us a JSON-decoded hash.
    def anthropic_input_schema(schema)
      schema = schema.deep_dup
      if schema.is_a?(Hash)
        schema.delete(:strict)
        schema.delete("strict")
      end
      schema
    end
end
