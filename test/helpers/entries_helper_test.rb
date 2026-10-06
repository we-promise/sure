require "test_helper"

class EntriesHelperTest < ActionView::TestCase
  include EntriesHelper

  test "dedupe_transfer_entries removes only the inflow side of a transfer" do
    outflow = entries(:transfer_out)
    inflow = entries(:transfer_in)

    result = dedupe_transfer_entries([ outflow, inflow ])

    assert_equal [ outflow ], result
  end

  test "dedupe_transfer_entries preserves original chronological order" do
    # Regression: a prior implementation grouped entries by transfer id with
    # `group_by`, which reordered the list so all non-transfer entries came
    # before the kept transfer entry, breaking chronological order in flat
    # (ungrouped) views.
    standalone = entries(:transaction)
    outflow = entries(:transfer_out)
    inflow = entries(:transfer_in)

    result = dedupe_transfer_entries([ standalone, outflow, inflow ])

    assert_equal [ standalone, outflow ], result
  end

  test "dedupe_transfer_entries leaves non-transfer entries untouched" do
    standalone = entries(:transaction)
    valuation = entries(:valuation)
    trade = entries(:trade)

    result = dedupe_transfer_entries([ standalone, valuation, trade ])

    assert_equal [ standalone, valuation, trade ], result
  end

  test "dedupe_transfer_entries keeps a transfer entry when its counterpart is absent" do
    outflow = entries(:transfer_out)

    result = dedupe_transfer_entries([ outflow ])

    assert_equal [ outflow ], result
  end
end
