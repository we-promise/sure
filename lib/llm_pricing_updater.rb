require "json"
require "net/http"
require "yaml"
require "date"

# Refreshes config/llm_pricing.yml from LiteLLM's price list. Model rows are
# rewritten line by line, so comments and fallback aliases survive, and new
# Claude and GPT tier releases are added. Run by bin/update_llm_pricing.
class LlmPricingUpdater
  SOURCE_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json".freeze

  # Sure provider => [LiteLLM key prefix, LiteLLM provider]
  LITELLM = {
    "openai" => [ "", "openai" ],
    "google" => [ "gemini/", "gemini" ],
    "anthropic" => [ "", "anthropic" ]
  }.freeze

  # Releases the fallback rows would otherwise only estimate. Dated snapshots
  # and "-4-0" style aliases are left to the existing rows.
  NEW_MODELS = {
    "openai" => /\Agpt-\d+(\.\d+)?-(astra|sol|terra|luna)\z/,
    "anthropic" => /\Aclaude-(fable|opus|sonnet|haiku)-\d{1,2}(-[1-9]\d?)?\z/
  }.freeze

  PROVIDER_LINE = /\A  (?<provider>[a-z]+):\s*\z/
  KEY_LINE = /\A {4}(?<model>[\w.\-]+):/
  MODEL_LINE = /\A(?<indent> {4})(?<model>[\w.\-]+): (?<anchor>&[\w.\-]+ )?(?<row>\{.*\})(?<comment> +#.*)?\z/
  # Anything above this per 1M tokens is treated as bad source data.
  MAX_PRICE = 10_000

  Result = Struct.new(:yaml, :changed, :added, :missing, keyword_init: true) do
    def summary
      [
        "Prices from [LiteLLM's price list](#{SOURCE_URL}). Check each change against the provider's official pricing page before merging; update `verified_on` only after reviewing every row.",
        section("Changed", changed),
        section("Added (point the family or tier fallback at the newest release if needed)", added),
        section("Not in LiteLLM, left unchanged", missing)
      ].compact.join("\n\n")
    end

    private
      def section(title, items)
        "### #{title}\n\n#{items.map { |item| "- #{item}" }.join("\n")}" if items.any?
      end
  end

  def self.fetch_prices
    response = Net::HTTP.get_response(URI(SOURCE_URL))
    raise "LiteLLM price list request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def initialize(yaml, prices)
    @lines = yaml.lines(chomp: true)
    @prices = prices
  end

  def call
    changed = []
    missing = []
    listed = Hash.new { |hash, provider| hash[provider] = [] }
    provider = nil

    lines = @lines.map do |line|
      if (match = PROVIDER_LINE.match(line))
        provider = match[:provider]
        next line
      end

      key = KEY_LINE.match(line)
      listed[provider] << key[:model] if key
      match = MODEL_LINE.match(line)
      next line unless match && LITELLM.key?(provider)

      model = match[:model]
      row = litellm_row(provider, model)
      current = YAML.safe_load(match[:row])

      if row.nil?
        missing << "`#{provider}/#{model}`"
        line
      elsif row == current
        line
      else
        changed << "`#{provider}/#{model}`: `#{flow(current)}` → `#{flow(row)}`"
        "#{match[:indent]}#{model}: #{match[:anchor]}#{flow(row)}#{match[:comment]}"
      end
    end

    added = add_new_models(lines, listed)
    yaml = lines.map { |line| "#{line}\n" }.join
    YAML.safe_load(yaml, permitted_classes: [ Date ], aliases: true) # never write a file that stops loading

    Result.new(yaml: yaml, changed: changed, added: added, missing: missing)
  end

  private
    def add_new_models(lines, listed)
      NEW_MODELS.flat_map do |provider, pattern|
        prefix, litellm_provider = LITELLM.fetch(provider)
        models = @prices.keys.filter_map do |key|
          model = key.delete_prefix(prefix)
          model if key.start_with?(prefix) && pattern.match?(model) && !listed[provider].include?(model) &&
            @prices[key].is_a?(Hash) && @prices[key]["litellm_provider"] == litellm_provider
        end
        rows = models.sort.reverse.filter_map do |model|
          row = litellm_row(provider, model)
          [ model, row ] if row
        end
        next [] if rows.empty?

        header = lines.index { |line| line == "  #{provider}:" }
        lines.insert(header + 1, "    # Added by bin/update_llm_pricing; check against the official pricing page.",
          *rows.map { |model, row| "    #{model}: #{flow(row)}" })
        rows.map { |model, row| "`#{provider}/#{model}`: `#{flow(row)}`" }
      end
    end

    def litellm_row(provider, model)
      prefix, litellm_provider = LITELLM.fetch(provider)
      entry = @prices["#{prefix}#{model}"]
      return unless entry.is_a?(Hash) && entry["litellm_provider"] == litellm_provider

      prompt = per_million(entry["input_cost_per_token"])
      completion = per_million(entry["output_cost_per_token"])
      return unless prompt && completion

      row = { "prompt" => prompt, "completion" => completion }
      # Sure prices cache reads for Anthropic only, at 0.1x input unless set.
      cache_read = per_million(entry["cache_read_input_token_cost"])
      row["cache_read"] = cache_read if provider == "anthropic" && cache_read && cache_read != (prompt * 0.1).round(6)

      threshold = entry.keys.filter_map { |key| key[/\Ainput_cost_per_token_above_(\d+)k_tokens\z/, 1]&.to_i }.min
      if threshold
        long_prompt = per_million(entry["input_cost_per_token_above_#{threshold}k_tokens"])
        long_completion = per_million(entry["output_cost_per_token_above_#{threshold}k_tokens"])
        if long_prompt && long_completion
          row["long_context"] = { "threshold" => threshold * 1000, "prompt" => long_prompt, "completion" => long_completion }
        end
      end

      row
    end

    def per_million(cost)
      return unless cost.is_a?(Numeric) && cost.finite? && cost >= 0

      price = (cost * 1_000_000).round(6)
      price.to_f if price <= MAX_PRICE
    end

    def flow(row)
      "{ #{row.map { |key, value| "#{key}: #{value.is_a?(Hash) ? flow(value) : value}" }.join(", ")} }"
    end
end
