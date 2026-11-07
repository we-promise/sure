require "test_helper"
require "open3"
require "rbconfig"

class NormalizedEncryptionCompatibilityTest < ActiveSupport::TestCase
  test "normalized encrypted query regressions pass in a fresh process" do
    env = ENV.to_h.slice(
      "PATH", "GEM_HOME", "GEM_PATH", "BUNDLE_PATH", "BUNDLE_GEMFILE",
      "BUNDLE_DEPLOYMENT", "BUNDLE_WITHOUT"
    )
    output, status = Open3.capture2e(
      env, RbConfig.ruby, "-rbundler/setup",
      Rails.root.join("test/standalone/normalized_encryption_compatibility_check.rb").to_s,
      chdir: Rails.root.to_s, unsetenv_others: true
    )

    assert status.success?, output
    assert_match(/13 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/, output)
  end
end
