require "test_helper"

# Every generation's schema is valid JSON Schema and compatible with OpenAI's strict
# mode, so the one schema works on every transport (strict response_format, the Responses API,
# Anthropic's output_config).
class AiSchemasTest < ActiveSupport::TestCase
  SAMPLES = {
    Ai::Generations::CategorizeTransactions => -> { new(transactions: [ { id: "t1" } ], categories: [ { id: "c1", name: "Coffee" } ], family: nil) },
    Ai::Generations::DetectMerchants => -> { new(transactions: [ { id: "t1" } ], merchants: [], family: nil) },
    Ai::Generations::EnhanceMerchants => -> { new(merchants: [ { id: "m1", name: "Shop" } ], family: nil) },
    Ai::Generations::SuggestBillSetup => -> { new(charges: [], categories: [], family: nil) }
  }.freeze

  test "every generation has a sample here" do
    generations = Rails.root.glob("app/models/ai/generations/*.rb").map { "Ai::Generations::#{_1.basename(".rb").to_s.camelize}".constantize }
    assert_equal generations.sort_by(&:name), SAMPLES.keys.sort_by(&:name)
  end

  SAMPLES.each do |generation, build|
    test "#{generation.name.demodulize}'s schema is strict-compatible" do
      assert_strict generation.instance_exec(&build).schema, generation.name
    end
  end

  private
    # OpenAI strict mode: every object lists all its properties as required and forbids others;
    # only the keywords strict mode accepts appear.
    ALLOWED = %w[type properties required additionalProperties items enum description minimum maximum].freeze

    def assert_strict(node, path)
      return unless node.is_a?(Hash)

      node = node.deep_stringify_keys
      assert_empty node.keys - ALLOWED, "#{path} uses keywords strict mode refuses: #{(node.keys - ALLOWED).join(", ")}"
      if Array(node["type"]).include?("object")
        assert_equal node["properties"].keys.sort, Array(node["required"]).sort, "#{path}: every property must be required"
        assert_equal false, node["additionalProperties"], "#{path}: additionalProperties must be false"
        node["properties"].each { |key, child| assert_strict(child, "#{path}.#{key}") }
      end
      assert_strict(node["items"], "#{path}[]") if node["items"]
      assert(Array(node["enum"]).all? { _1.nil? || _1.is_a?(String) || _1.is_a?(Numeric) }, "#{path}: enum values must be scalars") if node["enum"]
    end
end
