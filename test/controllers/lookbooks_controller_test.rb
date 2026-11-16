require "test_helper"

class LookbooksControllerTest < ActionDispatch::IntegrationTest
  test "renders a component preview in the lookbooks layout" do
    get "/design-system/preview/detail_row/default"

    assert_response :success
    assert_select "title", "Component Preview"
    assert_select "body", text: /TARGET 00023 SAN MATEO CA/
  end
end
