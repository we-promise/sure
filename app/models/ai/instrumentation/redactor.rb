# The one place AI instrumentation scrubs secrets (section 10). Every subscriber, and every
# `inspect` of an endpoint, goes through it, so a key never reaches a log, the debug log or a
# trace. Providers often quote the request back in an error, so error text is scrubbed too.
module Ai::Instrumentation::Redactor
  MASK = "[REDACTED]".freeze

  # [pattern, replacement]: key shapes are masked whole; a header or field keeps its name.
  PATTERNS = [
    [ /\b(?:sk|pk|rk)-[A-Za-z0-9_\-]{8,}/, MASK ],
    [ /\bAIza[0-9A-Za-z_\-]{20,}/, MASK ],
    [ /\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=\-]{8,}/i, "\\1 #{MASK}" ],
    [ /\b(api[_-]?key|access[_-]?token|secret|password)(["']?\s*[:=]\s*["']?)[^"'\s,&}]{4,}/i, "\\1\\2#{MASK}" ]
  ].freeze

  module_function

  # Masks known key shapes, plus every exact secret the caller passes (an endpoint's key).
  def scrub(text, secrets: [])
    return text if text.blank?

    scrubbed = Array(secrets).compact_blank.reduce(text.to_s) { |memo, secret| memo.gsub(secret.to_s, MASK) }
    PATTERNS.reduce(scrubbed) { |memo, (pattern, replacement)| memo.gsub(pattern, replacement) }
  end

  # A URL without credentials, query or fragment, the way AiHealth shows endpoints.
  def url(value) = value.present? ? AiHealth.redact_endpoint(value) : nil
end
