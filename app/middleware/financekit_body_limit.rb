# frozen_string_literal: true

# Bounds a FinanceKit batch upload before Rails reads it.
#
# The upload endpoint authenticates in its action and enforces
# Financekit::MAX_BYTES there, but Rails has already read and JSON-parsed the
# body by then: ActionController::Instrumentation logs
# `request.filtered_parameters` before any action code, and for a chunked
# request `ActionDispatch::Request#content_length` is the fully read
# `raw_post`. Left alone, an unauthenticated client could make the server
# buffer and parse a body of any size.
#
# A declared Content-Length over the limit is refused here. A chunked body is
# read no further than one byte past the limit, which is enough for the
# controller's own size check to see it is too large and answer 413.
class FinancekitBodyLimit
  PATH = %r{\A/api/v1/financekit/publishers/[^/]+/batches(?:\.[^./?]+)?\z}

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"].to_s.match?(PATH)

    limit = Financekit::MAX_BYTES
    if env["CONTENT_LENGTH"].to_i > limit
      return [ 413, { "content-type" => "application/json" }, [ { error: "payload_too_large" }.to_json ] ]
    end

    env["rack.input"] = LimitedInput.new(env["rack.input"], limit + 1) if env["rack.input"]
    @app.call(env)
  end

  # Reads through to the wrapped input, then reports end of stream once
  # `limit` bytes have been returned.
  class LimitedInput
    def initialize(io, limit)
      @io = io
      @limit = limit
      @read = 0
    end

    def read(length = nil, buffer = nil)
      remaining = @limit - @read
      if remaining <= 0
        buffer&.clear
        return length.nil? ? +"" : nil
      end

      data = @io.read(length.nil? ? remaining : [ length, remaining ].min)
      if data.nil?
        buffer&.clear
        return length.nil? ? +"" : nil
      end

      @read += data.bytesize
      buffer ? buffer.replace(data) : data
    end

    def gets
      line = @io.gets
      return nil if line.nil?

      line = line.byteslice(0, [ @limit - @read, 0 ].max)
      @read += line.bytesize
      line.empty? ? nil : line
    end

    def each
      while (chunk = read(16.kilobytes))
        yield chunk
      end
    end

    def rewind
      @read = 0
      @io.rewind if @io.respond_to?(:rewind)
    end

    def close
      @io.close if @io.respond_to?(:close)
    end
  end
end
