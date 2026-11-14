require "test_helper"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/sure/no_prompt_heredoc")

class RuboCop::Cop::Sure::NoPromptHeredocTest < ActiveSupport::TestCase
  def heredoc(lines) = "x = <<~PROMPT\n#{Array.new(lines) { "  line #{_1}\n" }.join}PROMPT\n"

  test "flags a heredoc over ten lines" do
    assert_equal 1, offenses(heredoc(11)).size
    assert_equal 1, offenses("x = <<~PROMPT\n#{Array.new(11) { "  \#{value} #{_1}\n" }.join}PROMPT\n").size
    assert_includes offenses(heredoc(11)).first.message, "app/prompts"
  end

  test "leaves short heredocs and plain strings alone" do
    assert_empty offenses(heredoc(10))
    assert_empty offenses(%(x = "#{"long " * 200}"))
  end

  test "nothing is allowlisted" do
    config = YAML.load_file(Rails.root.join(".rubocop.yml")).fetch("Sure/NoPromptHeredoc")

    assert_nil config["Exclude"], "move the prompt into app/prompts instead of excluding the file"
  end

  private
    def offenses(source)
      config = RuboCop::Config.new({ "Sure/NoPromptHeredoc" => { "Enabled" => true } }, "test.rb")
      cop = RuboCop::Cop::Sure::NoPromptHeredoc.new(config)
      processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, "test.rb")
      report = RuboCop::Cop::Commissioner.new([ cop ], [], raise_error: true).investigate(processed)
      assert_empty report.errors
      report.offenses
    end
end
