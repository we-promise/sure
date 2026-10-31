require "test_helper"
require_relative "../../../../support/financekit_test_helper"

# The batch upload endpoint is unauthenticated until the action runs, and
# Rails reads a body before any action code: Rack::MethodOverride parses a
# form-encoded one, Instrumentation logs `request.filtered_parameters`, and a
# chunked request's `content_length` is its fully read `raw_post`. These tests
# count the bytes anything reads from the request body, not only the status
# code, because the controller already answered 413 while the whole body had
# been read and parsed first. Nothing is stubbed: Rails' own JSON parsing runs.
class Api::V1::Financekit::BatchesBodyLimitTest < ActionDispatch::IntegrationTest
  include FinancekitTestHelper

  # Counts what is read through it, whoever reads it.
  class CountingInput
    attr_reader :bytes_read

    def initialize(body)
      @io = StringIO.new(body)
      @bytes_read = 0
    end

    def read(*args)
      data = @io.read(*args)
      @bytes_read += data.bytesize if data
      data
    end

    def gets
      line = @io.gets
      @bytes_read += line.bytesize if line
      line
    end

    def each
      while (chunk = read(16.kilobytes))
        yield chunk
      end
    end

    def rewind
      @io.rewind
    end

    def close; end
  end

  setup do
    financekit_setup
    @path = "/api/v1/financekit/publishers/#{@item.publisher_id}/batches"
    @oversized = JSON.generate({ "padding" => "a" * (2 * Financekit::MAX_BYTES) })
    @json = { "Authorization" => "Bearer invalid", "Content-Type" => "application/json" }
  end

  test "an oversized upload with a Content-Length is refused before any of it is read" do
    input = upload(@path, @oversized, @json)

    assert_response :payload_too_large
    assert_equal({ "error" => "payload_too_large" }, response.parsed_body)
    assert_equal 0, input.bytes_read, "no part of an oversized body should be read"
  end

  # Cut off at the limit, the body is not valid JSON; the middleware answers
  # before Rails' parameter parsing or the controller sees it.
  test "an oversized chunked upload is refused with the documented 413" do
    input = upload(@path, @oversized, @json, chunked: true)

    assert_response :payload_too_large
    assert_equal({ "error" => "payload_too_large" }, response.parsed_body)
    assert_operator input.bytes_read, :<=, Financekit::MAX_BYTES + 1,
      "read #{input.bytes_read} bytes of a #{@oversized.bytesize}-byte body"
  end

  test "a chunked upload within the limit is accepted whole" do
    payload = financekit_payload
    raw = JSON.generate(payload)
    headers = { "Authorization" => "Bearer #{@credential}", "Content-Type" => "application/json",
                "X-Sure-Payload-SHA256" => Digest::SHA256.hexdigest(raw), "Idempotency-Key" => payload.fetch("batch_id") }
    ApiRateLimiter.stubs(:limit).returns(nil)

    upload(@path, raw, headers, chunked: true)

    assert_response :accepted
    assert_equal raw, FinancekitBatch.sole.payload
  end

  # Rails squeezes repeated slashes and strips a trailing one before routing,
  # so these reach the same action.
  test "a trailing or repeated slash does not step around the limit" do
    [ "#{@path}/", "/#{@path}", @path.sub("/financekit/", "//financekit/") ].each do |path|
      input = upload(path, @oversized, @json)

      assert_response :payload_too_large, path
      assert_equal 0, input.bytes_read, "#{path} read #{input.bytes_read} bytes"
    end
  end

  # Rack::MethodOverride parses a form-encoded POST to look for `_method`.
  test "a form-encoded oversized upload is refused before any of it is read" do
    input = upload(@path, @oversized, @json.merge("Content-Type" => "application/x-www-form-urlencoded"))

    assert_response :payload_too_large
    assert_equal 0, input.bytes_read, "read #{input.bytes_read} bytes before the limit applied"
  end

  private
    def upload(path, body, headers, chunked: false)
      input = CountingInput.new(body)
      env = { "rack.input" => input }
      env.merge!("HTTP_TRANSFER_ENCODING" => "chunked", "CONTENT_LENGTH" => nil) if chunked
      post path, params: body, headers: headers, env: env
      input
    end
end

class FinancekitBodyLimitTest < ActiveSupport::TestCase
  UPLOAD = "/api/v1/financekit/publishers/abc/batches"

  setup do
    @seen = nil
    @app = FinancekitBodyLimit.new(->(env) { @seen = env["rack.input"].read; [ 200, {}, [ "ok" ] ] })
    @body = "b" * (Financekit::MAX_BYTES + 10)
  end

  test "leaves a body within the limit untouched" do
    body = "{\"ok\":true}"
    status, = @app.call(env_for("/api/v1/financekit/publishers/abc/batches", body))

    assert_equal 200, status
    assert_equal body, @seen
  end

  test "does not touch requests to any other path" do
    status, = @app.call(env_for("/api/v1/imports", @body))

    assert_equal 200, status
    assert_equal @body.bytesize, @seen.bytesize
  end

  test "does not touch a GET on the batch path" do
    status, = @app.call(env_for("/api/v1/financekit/publishers/abc/batches/xyz", @body, method: "GET"))

    assert_equal 200, status
    assert_equal @body.bytesize, @seen.bytesize
  end

  test "does not touch another method on the upload path" do
    env = env_for("/api/v1/financekit/publishers/abc/batches", @body, method: "PUT")

    status, = @app.call(env)

    assert_equal 200, status
    assert_equal @body.bytesize, @seen.bytesize
  end

  # The 413 must not depend on the app: cut off at the limit the body is not
  # valid JSON, and anything that reads params before the controller's own
  # size check would answer 400 instead.
  test "refuses a chunked body over the limit itself, without calling the app" do
    app_called = false
    app = FinancekitBodyLimit.new(->(_env) { app_called = true; [ 200, {}, [ "ok" ] ] })
    io = StringIO.new(@body)
    env = env_for("/api/v1/financekit/publishers/abc/batches", "")
    env.delete("CONTENT_LENGTH")
    env["HTTP_TRANSFER_ENCODING"] = "chunked"
    env["rack.input"] = io

    status, headers, body = app.call(env)

    assert_equal 413, status
    assert_equal "application/json", headers["content-type"]
    assert_equal({ "error" => "payload_too_large" }, JSON.parse(body.join))
    assert_not app_called, "the app should never see an oversized body"
    assert_equal Financekit::MAX_BYTES + 1, io.pos, "the body was read past one byte over the limit"
  end

  test "hands a chunked body within the limit to the app whole" do
    body = "c" * Financekit::MAX_BYTES
    env = env_for("/api/v1/financekit/publishers/abc/batches", body)
    env.delete("CONTENT_LENGTH")
    env["HTTP_TRANSFER_ENCODING"] = "chunked"

    status, = @app.call(env)

    assert_equal 200, status
    assert_equal body, @seen
  end

  # Puma spools a body and sets CONTENT_LENGTH (decoding a chunked one
  # first), and Rails then reads exactly that many bytes, so a declared length
  # within the limit needs no copy of the body.
  test "hands a declared body within the limit to the app as the same input, unread" do
    io = StringIO.new("{\"ok\":true}")
    env = env_for(UPLOAD, "")
    env["CONTENT_LENGTH"] = io.string.bytesize.to_s
    env["rack.input"] = io
    seen = nil
    app = FinancekitBodyLimit.new(->(e) { seen = [ e["rack.input"].equal?(io), io.pos ]; [ 200, {}, [ "ok" ] ] })

    status, = app.call(env)

    assert_equal 200, status
    assert_equal [ true, 0 ], seen, "the app should get the original input, with nothing read from it"
  end

  test "refuses a declared body over the limit without reading it or calling the app" do
    io = StringIO.new(@body)
    env = env_for(UPLOAD, "")
    env["CONTENT_LENGTH"] = @body.bytesize.to_s
    env["rack.input"] = io
    app_called = false
    app = FinancekitBodyLimit.new(->(_env) { app_called = true; [ 200, {}, [ "ok" ] ] })

    status, = app.call(env)

    assert_equal 413, status
    assert_not app_called
    assert_equal 0, io.pos
  end

  test "refuses an undeclared body over the limit, with or without Transfer-Encoding" do
    [ nil, "chunked" ].each do |transfer_encoding|
      io = StringIO.new(@body)
      status, = @app.call(undeclared_env(io, transfer_encoding))

      assert_equal 413, status, "Transfer-Encoding: #{transfer_encoding.inspect}"
      assert_equal Financekit::MAX_BYTES + 1, io.pos
      assert_nil @seen
    end
  end

  test "hands an undeclared body within the limit to the app intact, with or without Transfer-Encoding" do
    body = "c" * Financekit::MAX_BYTES
    [ nil, "chunked" ].each do |transfer_encoding|
      @seen = nil
      status, = @app.call(undeclared_env(StringIO.new(body), transfer_encoding))

      assert_equal 200, status
      assert_equal body, @seen
    end
  end

  # With Transfer-Encoding set, Rails reads the body to EOF rather than
  # CONTENT_LENGTH bytes, so a declared length is no bound there.
  test "still bounds a body that declares a small length alongside Transfer-Encoding" do
    io = StringIO.new(@body)
    env = undeclared_env(io, "chunked")
    env["CONTENT_LENGTH"] = "10"

    status, = @app.call(env)

    assert_equal 413, status
    assert_nil @seen
  end

  private
    def undeclared_env(io, transfer_encoding)
      env = env_for(UPLOAD, "")
      env.delete("CONTENT_LENGTH")
      env["HTTP_TRANSFER_ENCODING"] = transfer_encoding if transfer_encoding
      env["rack.input"] = io
      env
    end

    def env_for(path, body, method: "POST")
      Rack::MockRequest.env_for(path, method: method, input: body)
    end
end
