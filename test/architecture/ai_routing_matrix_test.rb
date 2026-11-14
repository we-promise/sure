require "test_helper"

# The routing table's invariants.
class AiRoutingMatrixTest < ActiveSupport::TestCase
  MATRIX = Ai::Routes::MATRIX
  LANES = %i[interactive prompt background].freeze
  PROVIDER_WORDS = /openai|anthropic|claude|gpt|gemini|llama|ollama|jev|mistral|cohere|openrouter|qwen/

  test "every feature has a lane, a consent level and a non-empty manifest" do
    MATRIX.each do |feature, spec|
      assert_includes LANES, spec[:lane], feature
      assert_includes %i[user family], spec[:consent], feature
      assert Ai::Routes.sends_for(Ai::Routes.consent_key(feature)).any?, "#{feature} sends nothing"
      assert spec[:needs] || spec[:route_of] || spec[:shadow_of], "#{feature} has no needs"
    end
  end

  test "every feature key is snake_case and names no provider or model" do
    MATRIX.each_key do |feature|
      assert_match(/\A[a-z]+(_[a-z]+)*\z/, feature.to_s)
      assert_no_match PROVIDER_WORDS, feature.to_s
    end
  end

  test "every shadow names its feature, and every consent_as a feature with the same consent level" do
    MATRIX.each do |feature, spec|
      if feature.to_s.start_with?("shadow_")
        assert_equal feature.to_s.delete_prefix("shadow_").to_sym, spec[:shadow_of], feature
      end
      next unless spec[:consent_as]

      assert_equal spec[:consent], MATRIX.fetch(spec[:consent_as])[:consent], feature
    end
  end

  test "there are exactly six consent rows, each with a label" do
    assert_equal 6, Ai::Routes.consent_keys.size
    Ai::Routes.consent_keys.each do |key|
      assert I18n.exists?("ai.consent_rows.#{key}", :en), "add ai.consent_rows.#{key} to config/locales/models/ai/en.yml"
    end
  end

  test "every item a feature sends is described" do
    MATRIX.values.flat_map { Array(_1[:sends]) }.uniq.each do |item|
      assert I18n.exists?("ai.sends.#{item}", :en), "add ai.sends.#{item} to config/locales/models/ai/en.yml"
    end
  end

  test "every reason the router gives has a message" do
    %i[not_configured capability_missing user_disabled].each do |reason|
      assert I18n.exists?("ai.availability.#{reason}.member", :en), reason
    end
  end

  test "the routing table in the AI pipeline guide is current" do
    guide = File.read(Rails.root.join("docs/llm-guides/ai-pipeline.md"))

    assert_includes guide, Ai::Routes.doc_table, "regenerate it: bin/rails ai:routes_doc"
  end

  # Every generation declares a feature in the table and has its own test file; every
  # requester declares the key Ai::Requesters lists it under.
  test "every generation declares a routed feature and has a test file" do
    generations = Rails.root.glob("app/models/ai/generations/*.rb").map { "Ai::Generations::#{_1.basename(".rb").to_s.camelize}".constantize }

    assert_not_empty generations
    generations.each do |generation|
      assert_includes MATRIX.keys, generation.feature_key, "#{generation} declares an unknown feature"
      assert Ai::Prompt.exists?(generation.prompt_key), "#{generation} names a missing prompt folder"
      test_file = Rails.root.join("test/models/ai/generations/#{generation.name.demodulize.underscore}_test.rb")
      assert test_file.exist?, "add #{test_file.relative_path_from(Rails.root)}"
    end
  end

  test "every requester declares the feature it's listed under" do
    Ai::Requesters::CLASSES.each do |feature, class_name|
      klass = class_name.constantize
      assert klass.include?(Ai::Requester), "#{class_name} should include Ai::Requester"
      assert_equal feature, klass.ai_feature, class_name
      assert klass.respond_to?(:from_ai_job), "#{class_name} should define .from_ai_job"
    end
  end
end
