require "test_helper"

class Ai::Transport::RubyLlmAdapterTest < ActiveSupport::TestCase
  setup do
    @transport = Ai::Transport.for(ai_endpoint(api_key: "sk-test-secret-123456"))
  end

  test "an option RubyLLM refuses becomes Refused" do
    error = assert_raises(Ai::Error::Refused) do
      @transport.send(:mapping_errors) { RubyLLM::Attachment.new("statement.pdf", resolution: :huge) }
    end

    assert_match "resolution must be one of", error.message
  end

  test "an ArgumentError from Sure's own code stays a bug" do
    assert_raises(ArgumentError) { @transport.send(:mapping_errors) { Integer("not a number") } }
  end

  test "a wrong call into RubyLLM stays a bug" do
    assert_raises(ArgumentError) { @transport.send(:mapping_errors) { RubyLLM::Attachment.new } }
  end

  test "an overload reported as a 400 stays a retryable outage" do
    response = Struct.new(:status, :body).new(400, { error: { message: "The model is currently overloaded" } }.to_json)

    assert_raises(Ai::Error::Upstream) do
      @transport.send(:mapping_errors) { raise RubyLLM::OverloadedError.new("The model is currently overloaded", response:) }
    end
  end
end
