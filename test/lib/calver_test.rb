require "test_helper"

class CalverTest < ActiveSupport::TestCase
  test "preserves calendar release identity" do
    version = Calver.from_release_tag("v2026.10.28")

    assert_equal "2026.10.28", version.to_s
    assert_equal "v2026.10.28", version.to_release_tag
    refute version.prerelease?
  end

  test "orders calendar releases and numbered prereleases numerically" do
    assert Calver.new("2026.10.28") > Calver.new("2026.9.30")
    assert Calver.new("2027.1.1") > Calver.new("2026.12.31")
    assert Calver.new("2026.10.28-rc.2") < Calver.new("2026.10.28-rc.10")
    assert Calver.new("2026.10.28-rc.10") < Calver.new("2026.10.28")
    assert Calver.new("2026.10.28-rc.2").prerelease?
    assert_equal Calver.new("2026.10.28"), Calver.from_release_tag("v2026.10.28")
  end

  test "retains legacy release tags used in release highlights history" do
    [ "0.7.5", "0.7.5-hotfix.1", "0.7.6-alpha.10" ].each do |tag|
      version = Calver.from_release_tag("v#{tag}")

      assert_equal Gem::Version.new(tag), version.version
      assert_equal "v#{tag}", version.to_release_tag
    end
  end

  test "accepts development fallback without a packaged release" do
    version = Calver.new("0.0.0-dev")

    assert_equal "0.0.0-dev", version.to_s
    assert version.prerelease?
    assert version < Calver.new("2026.10.28")
  end
end
