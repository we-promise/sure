require "test_helper"

class PropertyTest < ActiveSupport::TestCase
  test "property subtype is persisted on update" do
    property = properties(:townhouse)

    property.update!(subtype: "Townhouse")

    assert_equal "Townhouse", property.reload.subtype
  end
end
