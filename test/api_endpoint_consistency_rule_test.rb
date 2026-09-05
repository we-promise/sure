# frozen_string_literal: true

# Verifies the shared API endpoint checklist, Cursor adapter, and AGENTS.md entry point.
# If Rails fails to load (e.g. Sidekiq::Throttled), run the standalone script instead:
#   ruby test/support/verify_api_endpoint_consistency.rb

require "test_helper"

class ApiEndpointConsistencyRuleTest < ActiveSupport::TestCase
  RULE_PATH = ".cursor/rules/api-endpoint-consistency.mdc"
  GUIDE_PATH = "docs/llm-guides/api-endpoint-consistency.md"
  AGENTS_PATH = "AGENTS.md"

  def root
    @root ||= Rails.root
  end

  test "rule file exists" do
    assert File.exist?(root.join(RULE_PATH)), "Expected #{RULE_PATH} to exist"
  end

  test "rule has globs for API v1 paths" do
    content = File.read(root.join(RULE_PATH))
    assert_includes content, "globs: app/controllers/api/v1/**/*.rb, spec/requests/api/v1/**/*.rb, test/controllers/api/v1/**/*.rb"
    assert_includes content, "alwaysApply: false"
  end

  test "rule includes the shared checklist" do
    content = File.read(root.join(RULE_PATH))
    assert_includes content.lines.map(&:strip), "@#{GUIDE_PATH}"
    assert File.exist?(root.join(GUIDE_PATH)), "Expected #{GUIDE_PATH} to exist"
  end

  test "shared guide includes Minitest behavioral coverage section" do
    content = File.read(root.join(GUIDE_PATH))
    assert_includes content, "Minitest behavioral coverage"
    assert_includes content, "test/controllers/api/v1/{resource}_controller_test.rb"
    assert_includes content, "api_headers"
    assert_includes content, "X-Api-Key"
  end

  test "shared guide includes rswag docs-only section" do
    content = File.read(root.join(GUIDE_PATH))
    assert_includes content, "rswag is docs-only"
    assert_includes content, "expect"
    assert_includes content, "assert_"
    assert_includes content, "run_test!"
    assert_includes content, "rswag:specs:swaggerize"
  end

  test "shared guide includes same API key auth section" do
    content = File.read(root.join(GUIDE_PATH))
    assert_includes content, "Same API key auth"
    assert_includes content, "ApiKey.generate_secure_key"
    assert_includes content, "plain_key"
    assert_includes content, "Doorkeeper"
  end

  test "AGENTS.md references post-commit API consistency" do
    assert File.exist?(root.join(AGENTS_PATH)), "Expected #{AGENTS_PATH} to exist"
    content = File.read(root.join(AGENTS_PATH))
    assert_includes content, "Post-commit API consistency"
    assert_includes content, GUIDE_PATH
    assert_includes content, "Minitest"
    assert_includes content, "rswag"
    assert_includes content, "X-Api-Key"
  end
end
