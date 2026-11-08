# Token counts and cost for one request, named after RubyLLM::Tokens, which
# holds the same counts. `Usage` is taken twice already: installation telemetry
# (`Usage`) and the `llm_usages` table (`LlmUsage`).
#
# Counts a provider didn't report stay nil rather than 0, as RubyLLM 2.2 does (RubyLLM #1099, #1126).
# RubyLLM's `input` excludes cached tokens, unlike the raw APIs, so the prompt's size is
# input plus cache reads and cache writes (Anthropic reports writes apart from input).
Ai::Tokens = Data.define(:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens, :cost) do
  def initialize(input_tokens: nil, output_tokens: nil, cache_read_tokens: nil, cache_write_tokens: nil, cost: nil)
    super
  end

  # tokens: a RubyLLM::Tokens or nil; cost: a RubyLLM::Cost, a number or nil. A cost the
  # provider reported (OpenRouter's usage.cost, a BYOK key's upstream cost included) wins.
  def self.from_ruby_llm(tokens, cost = nil)
    reported = tokens.respond_to?(:reported_cost) ? tokens.reported_cost : nil
    total = cost.respond_to?(:total) ? cost.total : cost

    new(
      input_tokens: tokens&.input,
      output_tokens: tokens&.output,
      cache_read_tokens: tokens&.cache_read,
      cache_write_tokens: tokens&.cache_write,
      cost: reported || total
    )
  end

  def known? = [ input_tokens, output_tokens, cache_read_tokens, cache_write_tokens ].any?

  def prompt_tokens = sum(sum(input_tokens, cache_read_tokens), cache_write_tokens)

  def total_tokens = sum(prompt_tokens, output_tokens)

  private
    # Unknown plus unknown stays unknown; unknown plus a count is the count.
    def sum(a, b) = a.nil? && b.nil? ? nil : (a || 0) + (b || 0)
end
