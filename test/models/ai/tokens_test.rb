require "test_helper"

class Ai::TokensTest < ActiveSupport::TestCase
  test "the prompt counts cached tokens, which RubyLLM's input leaves out" do
    tokens = Ai::Tokens.from_ruby_llm(RubyLLM::Tokens.new(input: 512, output: 40, cache_read: 11_945, cache_write: 0))

    assert_equal 512, tokens.input_tokens
    assert_equal 12_457, tokens.prompt_tokens
    assert_equal 12_497, tokens.total_tokens
  end

  test "the prompt counts cache writes too" do
    tokens = Ai::Tokens.from_ruby_llm(RubyLLM::Tokens.new(input: 20, output: 10, cache_read: 100, cache_write: 1_000))

    assert_equal 1_120, tokens.prompt_tokens
    assert_equal 1_130, tokens.total_tokens
  end

  test "counts a provider didn't report stay unknown" do
    tokens = Ai::Tokens.from_ruby_llm(nil)

    assert_not tokens.known?
    assert_nil tokens.prompt_tokens
    assert_nil tokens.total_tokens
  end

  test "a reported cost wins over an estimate" do
    tokens = RubyLLM::Tokens.new(input: 100, output: 10, reported_cost: 0.0042)

    assert_in_delta 0.0042, Ai::Tokens.from_ruby_llm(tokens, 9.99).cost
    assert_in_delta 0.5, Ai::Tokens.from_ruby_llm(RubyLLM::Tokens.new(input: 1), 0.5).cost
  end

  test "a negative or non-finite cost is dropped, so the row is kept and its cost estimated" do
    assert_in_delta 0.5, Ai::Tokens.from_ruby_llm(RubyLLM::Tokens.new(input: 1, reported_cost: -0.1), 0.5).cost
    assert_nil Ai::Tokens.from_ruby_llm(RubyLLM::Tokens.new(input: 1), -1).cost
    assert_nil Ai::Tokens.from_ruby_llm(RubyLLM::Tokens.new(input: 1), Float::NAN).cost
  end
end
