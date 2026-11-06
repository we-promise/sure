require "test_helper"

# RubyLLM is set up as config/initializers/ruby_llm.rb describes.
class Ai::RubyLlmSetupTest < ActiveSupport::TestCase
  test "the gem is on the 2.x line the plan builds on" do
    assert Gem::Requirement.new("~> 2.1").satisfied_by?(Gem::Version.new(RubyLLM::VERSION)), RubyLLM::VERSION
  end

  # Sure records usage in llm_usages; RubyLLM's ledger writes a row per attempt only once its
  # table exists, so the table must never be created (spike: "RubyLLM's usage ledger").
  test "RubyLLM's usage ledger has no table to write to" do
    assert_not ActiveRecord::Base.connection.table_exists?("ruby_llm_usages")
  end

  test "no global keys or endpoints: every call goes through a per-endpoint context" do
    assert_nil RubyLLM.config.openai_api_key
    assert_nil RubyLLM.config.anthropic_api_key
    assert_equal Rails.logger, RubyLLM.config.logger
  end

  test "RubyLLM publishes its events through ActiveSupport::Notifications" do
    assert_equal ActiveSupport::Notifications, RubyLLM.config.instrumenter
  end
end
