require "test_helper"

class UuidFormatTest < ActiveSupport::TestCase
  test "valid matches canonical UUID values" do
    uuid = SecureRandom.uuid

    assert UuidFormat.valid?(uuid)
    assert UuidFormat.valid?(uuid.upcase)
  end

  test "valid rejects non UUID values" do
    refute UuidFormat.valid?(nil)
    refute UuidFormat.valid?("")
    refute UuidFormat.valid?("not-a-uuid")
    refute UuidFormat.valid?("#{SecureRandom.uuid}-extra")
  end
end
