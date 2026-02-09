# frozen_string_literal: true

# Standalone verification of the API endpoint consistency implementation (issue #944).
# Run without loading Rails: ruby test/support/verify_api_endpoint_consistency.rb
# Or with bundle: bundle exec ruby test/support/verify_api_endpoint_consistency.rb

def project_root
  dir = File.dirname(File.expand_path(__FILE__))
  loop do
    return dir if File.exist?(File.join(dir, "AGENTS.md")) && File.directory?(File.join(dir, ".cursor", "rules"))
    parent = File.dirname(dir)
    raise "Could not find project root (AGENTS.md + .cursor/rules)" if parent == dir
    dir = parent
  end
end

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

def assert_includes(content, substring, message)
  assert content.include?(substring), "#{message} (missing: #{substring.inspect})"
end

root = project_root
rule_path = File.join(root, ".cursor", "rules", "api-endpoint-consistency.mdc")
agents_path = File.join(root, "AGENTS.md")

assert File.exist?(rule_path), "Rule file should exist at #{rule_path}"
rule_content = File.read(rule_path)

assert_includes rule_content, "app/controllers/api/v1", "Rule must have glob for app/controllers/api/v1"
assert_includes rule_content, "spec/requests/api/v1", "Rule must have glob for spec/requests/api/v1"
assert_includes rule_content, "test/controllers/api/v1", "Rule must have glob for test/controllers/api/v1"
assert_includes rule_content, "Minitest behavioral coverage", "Rule must include Minitest section"
assert_includes rule_content, "test/controllers/api/v1/{resource}_controller_test.rb", "Rule must specify Minitest location"
assert_includes rule_content, "api_headers", "Rule must mention api_headers"
assert_includes rule_content, "X-Api-Key", "Rule must mention X-Api-Key"
assert_includes rule_content, "rswag is docs-only", "Rule must include rswag docs-only section"
assert_includes rule_content, "run_test!", "Rule must mention run_test!"
assert_includes rule_content, "rswag:specs:swaggerize", "Rule must mention swaggerize task"
assert_includes rule_content, "Same API key auth", "Rule must include API key auth section"
assert_includes rule_content, "ApiKey.generate_secure_key", "Rule must show API key pattern"
assert_includes rule_content, "plain_key", "Rule must mention plain_key"
assert_includes rule_content, "Doorkeeper", "Rule must mention Doorkeeper (to avoid OAuth in specs)"

assert File.exist?(agents_path), "AGENTS.md should exist"
agents_content = File.read(agents_path)
assert_includes agents_content, "Post-commit API consistency", "AGENTS.md must reference post-commit checklist"
assert_includes agents_content, "api-endpoint-consistency.mdc", "AGENTS.md must link to rule file"
assert_includes agents_content, "Minitest", "AGENTS.md must mention Minitest"
assert_includes agents_content, "rswag", "AGENTS.md must mention rswag"
assert_includes agents_content, "X-Api-Key", "AGENTS.md must mention X-Api-Key"

puts "OK: API endpoint consistency implementation verified (rule + AGENTS.md)."
