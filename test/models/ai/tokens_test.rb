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
    assert_nil (tokens + Ai::Tokens.new).input_tokens
  end

  test "adding keeps known counts and sums costs" do
    a = Ai::Tokens.new(input_tokens: 10, output_tokens: 5, cost: 0.25)
    b = Ai::Tokens.new(input_tokens: 3, cost: nil)

    sum = a + b

    assert_equal 13, sum.input_tokens
    assert_equal 5, sum.output_tokens
    assert_in_delta 0.25, sum.cost
    assert_equal a, a + nil
  end

  test "a reported cost wins over an estimate" do
    tokens = RubyLLM::Tokens.new(input: 100, output: 10, reported_cost: 0.0042)

    assert_in_delta 0.0042, Ai::Tokens.from_ruby_llm(tokens, 9.99).cost
    assert_in_delta 0.5, Ai::Tokens.from_ruby_llm(RubyLLM::Tokens.new(input: 1), 0.5).cost
  end
end
