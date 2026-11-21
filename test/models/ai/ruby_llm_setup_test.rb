require "test_helper"

# RubyLLM is set up as config/initializers/ruby_llm.rb describes.
class Ai::RubyLlmSetupTest < ActiveSupport::TestCase
  test "the gem is on the 2.x line the plan builds on" do
    assert Gem::Requirement.new("~> 2.2").satisfied_by?(Gem::Version.new(RubyLLM::VERSION)), RubyLLM::VERSION
  end

  # Sure records usage in llm_usages; RubyLLM's ledger writes a row per attempt only once its
  # table exists, so the table must never be created.
  test "RubyLLM's usage ledger has no table to write to" do
    assert_not ActiveRecord::Base.connection.table_exists?("ruby_llm_usages")
  end

  test "no global keys or endpoints: every call goes through a per-endpoint context" do
    assert_nil RubyLLM.config.openai_api_key
    assert_nil RubyLLM.config.anthropic_api_key
    assert_equal Rails.logger, RubyLLM.config.logger.__getobj__
  end

  # At debug RubyLLM logs response bodies and raw exceptions, which can quote a key back.
  test "RubyLLM never logs at debug, even when Rails does" do
    output = StringIO.new
    rails_logger = ActiveSupport::Logger.new(output, level: Logger::DEBUG)
    logger = RubyLlmLogger.new(rails_logger)

    assert_not logger.debug?
    assert_equal Logger::INFO, logger.level

    logger.debug("body with sk-secret")
    logger.debug { "block with sk-secret" }
    logger.warn("a warning")

    assert_no_match(/sk-secret/, output.string)
    assert_match(/a warning/, output.string)
  end

  test "Faraday's logger under RubyLLM writes no response body or error at debug" do
    output = StringIO.new
    logger = RubyLlmLogger.new(ActiveSupport::Logger.new(output, level: Logger::DEBUG))
    stubs = Faraday::Adapter::Test::Stubs.new { _1.post("/x") { [ 401, {}, "bad key sk-secret" ] } }
    connection = Faraday.new do |f|
      f.response :logger, logger, bodies: true, errors: true, log_level: :debug
      f.response :raise_error
      f.adapter :test, stubs
    end

    assert_raises(Faraday::UnauthorizedError) { connection.post("/x") }
    assert_empty output.string
  end

  test "RubyLLM publishes its events through ActiveSupport::Notifications" do
    assert_equal ActiveSupport::Notifications, RubyLLM.config.instrumenter
  end
end
