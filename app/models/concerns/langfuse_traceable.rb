module LangfuseTraceable
  private

    def langfuse_client
      return unless ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?

      Rails.configuration.x.langfuse
    end

    def create_langfuse_trace(name:, input:, session_id: nil, user_identifier: nil, start_time: nil)
      langfuse_client&.trace(
        name: name,
        input: input,
        session_id: session_id,
        user_id: user_identifier,
        environment: Rails.env,
        start_time: start_time
      )
    rescue => e
      Rails.logger.warn("Langfuse trace creation failed: #{e.class}: #{e.message}")
      nil
    end

    def finish_langfuse_trace(trace:, output:, level: nil)
      trace&.end(output: output, level: level)
    rescue => e
      Rails.logger.warn("Langfuse trace finalization failed: #{e.class}: #{e.message}")
      nil
    end
end
