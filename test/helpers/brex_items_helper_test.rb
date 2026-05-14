# frozen_string_literal: true

require "test_helper"

class BrexItemsHelperTest < ActionView::TestCase
  test "metadata uses translations with titleized fallback" do
    display = BrexItemsHelper::BrexAccountDisplay.new(
      id: "cash_1",
      name: "Operating Cash",
      kind: "cash",
      currency: "USD",
      status: "ACTIVE",
      blank_name: false
    )

    assert_equal "Brex • USD • Cash • Active", brex_account_metadata(display)

    fallback_display = BrexItemsHelper::BrexAccountDisplay.new(
      id: "unknown_1",
      name: "Unknown",
      kind: "custom_kind",
      currency: "USD",
      status: "custom_status",
      blank_name: false
    )

    assert_equal "Brex • USD • Custom Kind • Custom Status", brex_account_metadata(fallback_display)
  end
end
