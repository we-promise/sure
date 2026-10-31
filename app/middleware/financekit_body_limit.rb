# frozen_string_literal: true

# Bounds a FinanceKit batch upload before Rails reads it.
#
# The upload endpoint authenticates in its action and enforces
# Financekit::MAX_BYTES there, but Rails has already read and JSON-parsed the
# body by then: ActionController::Instrumentation logs
# `request.filtered_parameters` before any action code, which decodes the body
# (and swallows a parse error), and for a chunked request
# `ActionDispatch::Request#content_length` is the fully read `raw_post`. Left
# alone, an unauthenticated client could make the server buffer and parse a
# body of any size.
#
# It runs ahead of Rack::MethodOverride, which parses a form-encoded POST to
# look for `_method`. A declared Content-Length over the limit is refused
# without reading, and one within the limit is handed on untouched. A body
# with no declared length is read no further than one byte past the limit: if
# it overflows, it is refused here too, so a chunked oversize gets the same
# 413 whatever the app would do with a truncated body. A body within the
# limit is handed on as read.
class FinancekitBodyLimit
  PATH = %r{\A/api/v1/financekit/publishers/[^/]+/batches(?:\.[^./?]+)?\z}
  CHUNK = 16.kilobytes

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["REQUEST_METHOD"] == "POST" && upload_path?(env["PATH_INFO"])

    limit = Financekit::MAX_BYTES
    return payload_too_large if env["CONTENT_LENGTH"].to_i > limit
    return @app.call(env) if declared_length?(env)

    if (input = env["rack.input"])
      body = read_at_most(input, limit + 1)
      return payload_too_large if body.bytesize > limit

      env["rack.input"] = StringIO.new(body)
    end
    @app.call(env)
  end

  private
    # The same response BatchesController#protocol_error gives.
    def payload_too_large
      [ 413, { "content-type" => "application/json" }, [ { error: "payload_too_large" }.to_json ] ]
    end

    # Rails reads exactly CONTENT_LENGTH bytes unless Transfer-Encoding is
    # set, when it reads to EOF (ActionDispatch::Request#read_body_stream).
    # Puma decodes a chunked body, sets CONTENT_LENGTH and drops the header,
    # so behind Puma every upload takes this path and is never copied.
    def declared_length?(env)
      env["CONTENT_LENGTH"].to_s.match?(/\A\d+\z/) && !env.key?("HTTP_TRANSFER_ENCODING")
    end

    def read_at_most(input, max)
      body = String.new(encoding: Encoding::BINARY)
      while body.bytesize < max
        chunk = input.read([ CHUNK, max - body.bytesize ].min)
        break if chunk.nil? || chunk.empty?

        body << chunk
      end
      body
    end

    # Matched as the router will see it. Rails squeezes repeated slashes and
    # strips a trailing one before routing, so `/batches/` and `//api/...`
    # reach the upload action too.
    def upload_path?(path_info)
      ActionDispatch::Journey::Router::Utils.normalize_path(path_info.to_s).match?(PATH)
    end
end
