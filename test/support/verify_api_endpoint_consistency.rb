# frozen_string_literal: true

# Standalone verification of the shared API endpoint checklist and tool entry points.
# Run without loading Rails: ruby test/support/verify_api_endpoint_consistency.rb
# Or with bundle: bundle exec ruby test/support/verify_api_endpoint_consistency.rb
#
# Option: pass --compliance to also scan the current API codebase and report violations
# (rswag specs using OAuth instead of API key, missing Minitest for API controllers,
# rswag specs with expect/assert).

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
guide_relative_path = "docs/llm-guides/api-endpoint-consistency.md"
guide_path = File.join(root, guide_relative_path)
agents_path = File.join(root, "AGENTS.md")

assert File.exist?(rule_path), "Rule file should exist at #{rule_path}"
rule_content = File.read(rule_path)

assert_includes rule_content, "globs: app/controllers/api/v1/**/*.rb, spec/requests/api/v1/**/*.rb, test/controllers/api/v1/**/*.rb", "Rule must retain scoped API v1 globs"
assert_includes rule_content, "alwaysApply: false", "Rule must remain scoped"
assert rule_content.lines.map(&:strip).include?("@#{guide_relative_path}"), "Rule must include the shared guide"

assert File.exist?(guide_path), "Shared guide should exist at #{guide_path}"
guide_content = File.read(guide_path)

assert_includes guide_content, "Minitest behavioral coverage", "Guide must include Minitest section"
assert_includes guide_content, "test/controllers/api/v1/{resource}_controller_test.rb", "Guide must specify Minitest location"
assert_includes guide_content, "api_headers", "Guide must mention api_headers"
assert_includes guide_content, "X-Api-Key", "Guide must mention X-Api-Key"
assert_includes guide_content, "rswag is docs-only", "Guide must include rswag docs-only section"
assert_includes guide_content, "expect", "Guide must prohibit RSpec behavioral assertions"
assert_includes guide_content, "assert_", "Guide must prohibit Minitest assertions in rswag specs"
assert_includes guide_content, "run_test!", "Guide must mention run_test!"
assert_includes guide_content, "rswag:specs:swaggerize", "Guide must mention swaggerize task"
assert_includes guide_content, "Same API key auth", "Guide must include API key auth section"
assert_includes guide_content, "ApiKey.generate_secure_key", "Guide must show API key pattern"
assert_includes guide_content, "plain_key", "Guide must mention plain_key"
assert_includes guide_content, "Doorkeeper", "Guide must mention Doorkeeper (to avoid OAuth in specs)"

assert File.exist?(agents_path), "AGENTS.md should exist"
agents_content = File.read(agents_path)
assert_includes agents_content, "Post-commit API consistency", "AGENTS.md must reference post-commit checklist"
assert_includes agents_content, guide_relative_path, "AGENTS.md must link to shared guide"
assert_includes agents_content, "Minitest", "AGENTS.md must mention Minitest"
assert_includes agents_content, "rswag", "AGENTS.md must mention rswag"
assert_includes agents_content, "X-Api-Key", "AGENTS.md must mention X-Api-Key"

puts "OK: API endpoint consistency implementation verified (shared guide + Cursor adapter + AGENTS.md)."

if ARGV.include?("--compliance")
  puts "\n--- Compliance check (current APIs) ---"
  spec_dir = File.join(root, "spec", "requests", "api", "v1")
  test_dir = File.join(root, "test", "controllers", "api", "v1")
  app_controllers_dir = File.join(root, "app", "controllers", "api", "v1")

  rswag_oauth = []
  rswag_assertions = []
  missing_minitest = []

  if File.directory?(spec_dir)
    Dir.glob(File.join(spec_dir, "*_spec.rb")).each do |path|
      basename = File.basename(path, "_spec.rb")
      next if basename == "auth"
      content = File.read(path)
      if content.include?("Doorkeeper") || content.include?("Bearer") || content.include?("access_token")
        rswag_oauth << "#{basename}_spec.rb"
      end
      rswag_assertions << "#{basename}_spec.rb" if content.include?("expect(") || content.include?("assert_")
    end
  end

  skip_controllers = %w[base_controller test_controller]
  if File.directory?(app_controllers_dir)
    Dir.glob(File.join(app_controllers_dir, "*_controller.rb")).each do |path|
      basename = File.basename(path, ".rb")
      next if skip_controllers.include?(basename)
      test_path = File.join(test_dir, "#{basename}_test.rb")
      missing_minitest << basename unless File.exist?(test_path)
    end
  end

  if rswag_oauth.any?
    puts "rswag using OAuth (should use API key per rule): #{rswag_oauth.join(", ")}"
  else
    puts "rswag auth: all specs use API key."
  end

  if rswag_assertions.any?
    puts "rswag with expect/assert (should be docs-only): #{rswag_assertions.join(", ")}"
  else
    puts "rswag: no expect/assert found (docs-only)."
  end

  if missing_minitest.any?
    puts "API v1 controllers missing Minitest: #{missing_minitest.join(", ")}"
  else
    puts "Minitest: all API v1 controllers have a test file."
  end

  puts "---"
end
