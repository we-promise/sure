require "test_helper"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/sure/no_ai_env")

class RuboCop::Cop::Sure::NoAiEnvTest < ActiveSupport::TestCase
  PERMANENT = %w[app/models/ai/legacy_env_config.rb db/migrate/**/*].freeze

  test "flags ENV reads of AI configuration" do
    [
      'ENV["OPENAI_MODEL"]',
      'ENV.fetch("EMBEDDING_DIMENSIONS", 1024)',
      '::ENV["LLM_PROVIDER"].presence',
      'ENV.key?("JEV_API_KEY")',
      'ENV["EXTERNAL_ASSISTANT_URL"]',
      'ENV["AI_RESPONSE_TIMEOUT"]'
    ].each { |source| assert_equal 1, offenses(source).size, source }
  end

  test "leaves other variables alone" do
    [
      'ENV["LANGFUSE_PUBLIC_KEY"]',
      'ENV["AI_DEBUG_MODE"]',
      'ENV["HTTPS_PROXY"]',
      'ENV["RAILS_AI_MAX_THREADS"]',
      "ENV[name]",
      'settings["OPENAI_MODEL"]'
    ].each { |source| assert_empty offenses(source), source }
  end

  test "points to where AI configuration goes" do
    assert_includes offenses('ENV["OPENAI_MODEL"]').first.message, "docs/llm-guides/ai-pipeline.md"
  end

  # The allowlist in .rubocop.yml may only shrink: once a file stops reading AI ENV, it leaves.
  test "every allowlisted file still reads AI ENV" do
    excluded = YAML.load_file(Rails.root.join(".rubocop.yml")).dig("Sure/NoAiEnv", "Exclude") - PERMANENT

    excluded.each do |path|
      source = File.read(Rails.root.join(path))
      assert offenses(source).any?, "#{path} no longer reads AI ENV; remove it from Sure/NoAiEnv's allowlist in .rubocop.yml"
    end
  end

  private
    def offenses(source)
      config = RuboCop::Config.new({ "Sure/NoAiEnv" => { "Enabled" => true } }, "test.rb")
      cop = RuboCop::Cop::Sure::NoAiEnv.new(config)
      processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, "test.rb")
      report = RuboCop::Cop::Commissioner.new([ cop ], [], raise_error: true).investigate(processed)
      assert_empty report.errors
      report.offenses
    end
end
