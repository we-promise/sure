require "test_helper"

class CustomConfirmTest < ActiveSupport::TestCase
  # `confirm_dialog_controller` assigns `body` to innerHTML so bodies like
  # accounts' `confirm_body_html` can carry markup. Every caller passes a
  # user-named record, so an account named "<img src=x onerror=…>" would run
  # when someone opened the confirmation.
  test "escapes the resource name in the HTML-rendered body" do
    data = CustomConfirm.for_resource_deletion("<img src=x onerror=alert(1)>").to_data_attribute

    assert_includes data[:body], "&lt;img src=x onerror=alert(1)&gt;"
    assert_no_match(/<img/, data[:body])
  end

  # Title and button label reach the dialog through textContent, so they are
  # inert — pinned here so a future move to innerHTML doesn't pass silently.
  test "keeps the English copy the hardcoded strings produced" do
    data = CustomConfirm.for_resource_deletion("rule").to_data_attribute

    assert_equal "Delete Rule?", data[:title]
    assert_equal "Are you sure you want to delete rule? This is not reversible.", data[:body]
    assert_equal "Delete Rule", data[:confirmText]
  end

  test "high severity picks the destructive button variant" do
    assert_equal "destructive", CustomConfirm.for_resource_deletion("rule", high_severity: true).to_data_attribute[:variant]
    assert_equal "outline-destructive", CustomConfirm.for_resource_deletion("rule").to_data_attribute[:variant]
  end
end
