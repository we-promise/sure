require "openssl"

class Provider::SentryAiMonitoring
  AI_SAMPLE_CONTEXT = { ai_monitoring: true }.freeze
  TELEMETRY_KEY_PURPOSE = "sentry_ai_monitoring_identifier".freeze

  class << self
    def with_chat_span(provider:, model:, conversation_id: nil, user_identifier: nil)
      with_span(
        op: "gen_ai.chat",
        name: "chat #{model}",
        provider: provider,
        model: model,
        conversation_id: conversation_id,
        user_identifier: user_identifier,
        attributes: {
          "gen_ai.operation.name" => "chat"
        }
      ) { |span| yield(span) }
    end

    def with_tool_span(function_name:, description: nil, conversation_id: nil, user_identifier: nil)
      with_span(
        op: "gen_ai.execute_tool",
        name: "execute_tool #{function_name}",
        provider: nil,
        model: nil,
        conversation_id: conversation_id,
        user_identifier: user_identifier,
        attributes: {
          "gen_ai.operation.name" => "execute_tool",
          "gen_ai.tool.name" => function_name,
          "gen_ai.tool.description" => description
        }
      ) { |span| yield(span) }
    end

    def set_usage(span, usage)
      return unless span && usage.present?

      input_tokens = integer_from(usage["input_tokens"] || usage["prompt_tokens"])
      output_tokens = integer_from(usage["output_tokens"] || usage["completion_tokens"])
      total_tokens = integer_from(usage["total_tokens"]) || [ input_tokens, output_tokens ].compact.sum

      set_data(span, "gen_ai.usage.input_tokens", input_tokens)
      set_data(span, "gen_ai.usage.output_tokens", output_tokens)
      set_data(span, "gen_ai.usage.total_tokens", total_tokens)
      set_data(
        span,
        "gen_ai.usage.input_tokens.cached",
        integer_from(usage["cached_tokens"] || usage["cache_read_input_tokens"])
      )
      set_data(
        span,
        "gen_ai.usage.input_tokens.cache_write",
        integer_from(usage["cache_write_input_tokens"] || usage["cache_creation_input_tokens"])
      )
      set_data(
        span,
        "gen_ai.usage.output_tokens.reasoning",
        integer_from(usage["reasoning_tokens"] || usage["output_tokens_reasoning"])
      )
    end

    def set_error(span, error)
      return unless span

      set_data(span, "gen_ai.response.error_type", error.class.name)
    end

    private
      def with_span(op:, name:, provider:, model:, conversation_id:, user_identifier:, attributes:)
        return yield(nil) unless active?

        transaction = Sentry.start_transaction(
          name: name,
          op: op,
          source: :custom,
          custom_sampling_context: AI_SAMPLE_CONTEXT
        )
        return yield(nil) unless transaction

        set_common_data(
          transaction,
          provider: provider,
          model: model,
          conversation_id: conversation_id,
          user_identifier: user_identifier,
          attributes: attributes
        )

        result = yield(transaction)
        transaction.set_status("ok")
        result
      rescue => e
        if transaction
          set_error(transaction, e)
          transaction.set_status("internal_error")
        end
        raise
      ensure
        transaction&.finish
      end

      def active?
        defined?(Sentry) && Sentry.respond_to?(:initialized?) && Sentry.initialized?
      end

      def set_common_data(span, provider:, model:, conversation_id:, user_identifier:, attributes:)
        set_data(span, "gen_ai.system", provider) if provider.present?
        set_data(span, "gen_ai.request.model", model) if model.present?
        set_data(span, "gen_ai.conversation.id", telemetry_identifier("conversation", conversation_id))
        set_data(span, "user.id", telemetry_identifier("user", user_identifier))

        attributes.each { |key, value| set_data(span, key, value) if value.present? }
      end

      def set_data(span, key, value)
        return if value.nil?

        span.set_data(key, value)
      end

      def telemetry_identifier(namespace, value)
        identifier = value.to_s.strip
        return if identifier.blank?

        OpenSSL::HMAC.hexdigest("SHA256", telemetry_secret, "#{namespace}:#{identifier}")
      end

      def telemetry_secret
        Rails.application.key_generator.generate_key(TELEMETRY_KEY_PURPOSE, 32)
      end

      def integer_from(value)
        return if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
