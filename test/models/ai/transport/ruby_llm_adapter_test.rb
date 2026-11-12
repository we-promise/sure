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

  test "the RubyLLM context for chat completions splits think tags, so answers are what's parsed" do
    context = @transport.send(:ruby_llm_context)

    assert_equal true, context.config.split_think_tags
  end
end
