# frozen_string_literal: true

# Turns transport-level failures into the including provider's own ApiError.
#
# A connection that never opened, timed out, was reset, or answered with
# something that is not JSON is the data source being unavailable — the same
# thing as a 5xx, and nothing a caller can act on differently. Left
# untranslated they escape as unexpected exceptions, so the chain adapters
# cannot recognise them and the user is told something went wrong with Sure
# rather than with a public explorer.
#
# The message deliberately carries only the error class: a transport error's
# message can contain the full URL, and these are logged.
module Provider::HttpTransport
  TRANSPORT_ERRORS = [
    Timeout::Error,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Net::WriteTimeout,
    Net::HTTPBadResponse,
    SocketError,
    EOFError,
    IOError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::ETIMEDOUT,
    Errno::EPIPE,
    OpenSSL::SSL::SSLError,
    HTTParty::Error,
    JSON::ParserError
  ].freeze

  private
    def translate_transport_errors
      yield
    rescue *TRANSPORT_ERRORS => e
      raise self.class::ApiError, "#{self.class.name.demodulize} is unavailable (#{e.class})"
    end
end
