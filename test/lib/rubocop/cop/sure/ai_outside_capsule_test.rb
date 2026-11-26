require "test_helper"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/sure/ai_outside_capsule")

class RuboCop::Cop::Sure::AiOutsideCapsuleTest < ActiveSupport::TestCase
  ALLOWED = [ "app/models/eval/**/*.rb", "lib/tasks/evals.rake" ].freeze

  test "flags an opt-out outside evals" do
    [ "Ai::Capsule.outside { generation.call }", "::Ai::Capsule.outside { generation.call }" ].each do |source|
      assert_equal 1, offenses(source).size, source
    end
    assert_includes offenses("Ai::Capsule.outside { }").first.message, "ai-pipeline.md"
  end

  test "leaves other capsule calls alone" do
    [ "Ai::Capsule.within(queue) { generation.call }", "Capsule.outside { generation.call }",
      "Ai::Config.with(config) { generation.call }" ].each { |source| assert_empty offenses(source), source }
  end

  test "the allowlist is only the eval runner and its rake tasks" do
    config = YAML.load_file(Rails.root.join(".rubocop.yml")).fetch("Sure/AiOutsideCapsule")

    assert_equal ALLOWED, config.fetch("Exclude")
    assert_includes config.fetch("Include"), "lib/**/*.rake"
  end

  test "every allowlisted path still needs the opt-out" do
    ALLOWED.each do |pattern|
      paths = Rails.root.glob(pattern)
      assert_not_empty paths, "#{pattern} matches no files"
      assert paths.any? { _1.read.include?("Ai::Capsule.outside") }, "#{pattern} no longer uses Ai::Capsule.outside"
    end
  end

  private
    def offenses(source)
      config = RuboCop::Config.new({ "Sure/AiOutsideCapsule" => { "Enabled" => true } }, "test.rb")
      cop = RuboCop::Cop::Sure::AiOutsideCapsule.new(config)
      processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, "test.rb")
      report = RuboCop::Cop::Commissioner.new([ cop ], [], raise_error: true).investigate(processed)
      assert_empty report.errors
      report.offenses
    end
end
