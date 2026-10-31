require "test_helper"

class SureVersionTest < ActiveSupport::TestCase
  test "source checkouts without generated metadata have a valid development version" do
    path = Rails.root.join(".sure-version")
    Rails.root.stubs(:join).with(".sure-version").returns(path)
    path.stubs(:read).raises(Errno::ENOENT)
    assert_equal "0.0.0-dev", Sure.version.to_s
    assert Sure.version.prerelease?
  end

  test "packaged applications report the generated release identity" do
    path = Rails.root.join(".sure-version")
    Rails.root.stubs(:join).with(".sure-version").returns(path)
    path.stubs(:read).returns("2026.10.28\n")
    assert_equal "2026.10.28", Sure.version.to_s
    assert_equal "v2026.10.28", Sure.version.to_release_tag
    assert_not Sure.version.prerelease?
  end
end
