# Down marks: the smallest thing an error proves broken is skipped for 60 seconds,
# so the next call doesn't wait for the same timeout. Kept in Rails.cache, so every process on
# the instance sees them.
#
# - The server (host and port) when no response came back, or a local endpoint timed out or
#   failed as a whole: every endpoint row on it is skipped.
# - The key on Unauthorized or NoCredit: that endpoint row.
# - The model on that key otherwise: a gateway's 503 or 429 usually belongs to one upstream model.
#
# Escalation (InvalidOutput, ContextTooLong) marks nothing: the endpoint is fine.
module Ai::DownMarks
  TTL = 60.seconds
  FAILOVER = [ Ai::Error::Timeout, Ai::Error::Upstream, Ai::Error::RateLimited, Ai::Error::Unreachable,
               Ai::Error::Unauthorized, Ai::Error::NoCredit, Ai::Error::ModelMissing ].freeze

  module_function

  def mark(route, error)
    Rails.cache.write(key_for(route, error), error.class.name.demodulize, expires_in: TTL)
  end

  def down?(route)
    [ server_key(route.endpoint), key_key(route.endpoint), model_key(route) ].any? { Rails.cache.exist?(_1) }
  end

  def key_for(route, error)
    case error
    when Ai::Error::Unreachable then server_key(route.endpoint)
    when Ai::Error::Timeout, Ai::Error::Upstream then route.endpoint.local? ? server_key(route.endpoint) : model_key(route)
    when Ai::Error::Unauthorized, Ai::Error::NoCredit then key_key(route.endpoint)
    else model_key(route)
    end
  end

  # Host and port: a chat server can be down while the embedding server on the same host is up.
  def server_key(endpoint)
    uri = URI.parse(endpoint.base_url.to_s)
    "ai/down/server/#{uri.host ? "#{uri.host}:#{uri.port}" : endpoint.name}"
  rescue URI::InvalidURIError
    "ai/down/server/#{endpoint.name}"
  end

  # A short digest of the key, so a replaced key isn't skipped for the old one's mark.
  def key_key(endpoint) = "ai/down/key/#{endpoint.name}/#{Digest::SHA256.hexdigest(endpoint.api_key.to_s).first(12)}"

  def model_key(route) = "ai/down/model/#{route.endpoint.name}/#{route.model.name}"
end
