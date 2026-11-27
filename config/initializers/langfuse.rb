require "langfuse_tracing"

if ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?
  Rails.configuration.x.langfuse = LangfuseTracing.new(
    public_key: ENV.fetch("LANGFUSE_PUBLIC_KEY"),
    secret_key: ENV.fetch("LANGFUSE_SECRET_KEY"),
    host: ENV["LANGFUSE_HOST"].presence || "https://cloud.langfuse.com"
  )

  at_exit { Rails.configuration.x.langfuse.shutdown }
end
