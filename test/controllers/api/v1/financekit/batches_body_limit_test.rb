require "test_helper"
require_relative "../../../../support/financekit_test_helper"

# The batch upload endpoint is unauthenticated until the action runs, and
# Rails parses a JSON body before any action code: Instrumentation logs
# `request.filtered_parameters`, and a chunked request's `content_length` is
# its fully read `raw_post`. These tests measure how much of an oversized body
# reaches the JSON parser, not only the status code, because the controller
# already answered 413 while the whole body had been read and parsed first.
class Api::V1::Financekit::BatchesBodyLimitTest < ActionDispatch::IntegrationTest
  include FinancekitTestHelper

  setup do
    financekit_setup
    @path = "/api/v1/financekit/publishers/#{@item.publisher_id}/batches"
    @oversized = JSON.generate({ "padding" => "a" * (2 * Financekit::MAX_BYTES) })
    @decoded_sizes = []
    decoded_sizes = @decoded_sizes
    real_decode = ActiveSupport::JSON.method(:decode)
    ActiveSupport::JSON.stubs(:decode).with do |raw, *|
      decoded_sizes << raw.to_s.bytesize
      true
    end.returns({})
    @real_decode = real_decode
  end

  test "an oversized upload with a Content-Length is refused before any of it is parsed" do
    post @path, params: @oversized,
      headers: { "Authorization" => "Bearer invalid", "Content-Type" => "application/json" }

    assert_response :payload_too_large
    assert_equal({ "error" => "payload_too_large" }, @real_decode.call(response.body))
    assert_empty @decoded_sizes, "no part of an oversized body should reach the JSON parser"
  end

  test "a chunked upload is read no further than the limit" do
    post @path, params: @oversized,
      headers: { "Authorization" => "Bearer invalid", "Content-Type" => "application/json" },
      env: { "HTTP_TRANSFER_ENCODING" => "chunked", "CONTENT_LENGTH" => nil }

    assert_response :payload_too_large
    assert @decoded_sizes.all? { |size| size <= Financekit::MAX_BYTES + 1 },
      "parsed #{@decoded_sizes.max} bytes of a #{@oversized.bytesize}-byte body"
  end
end

class FinancekitBodyLimitTest < ActiveSupport::TestCase
  setup do
    @seen = nil
    @app = FinancekitBodyLimit.new(->(env) { @seen = env["rack.input"].read; [ 200, {}, [ "ok" ] ] })
    @body = "b" * (Financekit::MAX_BYTES + 10)
  end

  # gets has no length argument under the Rack input contract, so an endless
  # line must not be pulled from the stream whole before the cap applies.
  test "gets reads no further than the limit on a line with no newline" do
    io = StringIO.new("c" * (Financekit::MAX_BYTES * 3))
    input = FinancekitBodyLimit::LimitedInput.new(io, Financekit::MAX_BYTES + 1)

    line = input.gets

    assert_equal Financekit::MAX_BYTES + 1, line.bytesize
    assert_operator io.pos, :<=, Financekit::MAX_BYTES + 1, "the underlying stream was read past the cap"
    assert_nil input.gets, "nothing more is returned once the cap is reached"
  end

  test "gets still returns whole lines under the limit" do
    input = FinancekitBodyLimit::LimitedInput.new(StringIO.new("one\ntwo\n"), 100)

    assert_equal "one\n", input.gets
    assert_equal "two\n", input.gets
    assert_nil input.gets
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

  test "caps a chunked body one byte past the limit so the controller can refuse it" do
    env = env_for("/api/v1/financekit/publishers/abc/batches", @body)
    env.delete("CONTENT_LENGTH")
    env["HTTP_TRANSFER_ENCODING"] = "chunked"

    @app.call(env)

    assert_equal Financekit::MAX_BYTES + 1, @seen.bytesize
  end

  private
    def env_for(path, body, method: "POST")
      Rack::MockRequest.env_for(path, method: method, input: body)
    end
end
