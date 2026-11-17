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
  # Failovers that pass on their own; the others (a bad key, no credit, a missing model) need a fix.
  PASSING = [ Ai::Error::Timeout, Ai::Error::Upstream, Ai::Error::RateLimited, Ai::Error::Unreachable ].freeze

  module_function

  def mark(route, error)
    Rails.cache.write(key_for(route, error), error.class.name.demodulize, expires_in: TTL)
  end

  # :up, :passing (down for a failure that passes on its own: a timeout, an outage) or :failing
  # (down for one that needs a fix). One read of the marks, so whether a route is skipped and why
  # can't disagree when a mark expires in between.
  def state(route)
    reasons = [ server_key(route.endpoint), key_key(route.endpoint), model_key(route) ].filter_map { Rails.cache.read(_1) }
    return :up if reasons.empty?

    reasons.all? { |name| PASSING.any? { _1.name.demodulize == name } } ? :passing : :failing
  end

  def down?(route) = state(route) != :up

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

  # A short digest of the server, the key and static headers (a gateway may authenticate by either),
  # so a replaced credential isn't skipped for the old one's mark, and another server that shares
  # the endpoint's name and key (an eval run's) isn't skipped for this one's.
  def key_key(endpoint) = "ai/down/key/#{credential(endpoint)}"

  # The model on that credential, so a replaced key isn't skipped for the old one's 429 either.
  def model_key(route) = "ai/down/model/#{credential(route.endpoint)}/#{route.model.name}"

  def credential(endpoint)
    digest = Digest::SHA256.hexdigest([ endpoint.base_url.to_s.chomp("/"), endpoint.api_key.to_s, endpoint.extra_headers.sort ].to_json).first(12)
    "#{endpoint.name}/#{digest}"
  end
end
