# A DebugLogEntry for every AI call that fails, so an operator sees it on the
# debug page with its feature, route and error, never its key or prompt. Health probes and
# busy model hosts are skipped (Ai::Instrumentation.unreported?).
class Ai::Instrumentation::DebugLogSubscriber
  def call(event)
    payload = event.payload
    return if payload[:error].blank? || Ai::Instrumentation.unreported?(event)

    DebugLogEntry.capture(
      category: "ai",
      level: "error",
      message: "AI #{payload[:feature] || "call"} failed: #{payload[:error].to_s.demodulize}",
      source: self.class.name,
      provider_key: payload.dig(:endpoint, :name),
      family_id: payload[:family_id],
      metadata: {
        feature: payload[:feature],
        route: payload[:route],
        endpoint: payload[:endpoint],
        error_class: payload[:error],
        error_message: payload[:error_message],
        http_status: payload[:http_status],
        call_id: payload[:call_id],
        correlation_id: payload[:correlation_id]
      }.compact
    )
  end
end
