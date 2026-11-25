require "test_helper"

class EntriesHelperTest < ActionView::TestCase
  include EntriesHelper

  test "compact render options preserve row context and valuation locals" do
    transaction = entries(:transaction)
    options = compact_entry_render_options(transaction, view_ctx: "global", is_filtered: true, in_split_group: true, flat: true)
    assert_equal "transactions/compact_transaction", options[:partial]
    assert_equal "global", options[:locals][:view_ctx]
    assert options[:locals][:is_filtered]
    assert options[:locals][:in_split_group]
    assert options[:locals][:flat]

    trade_options = compact_entry_render_options(entries(:trade), in_split_group: true)
    assert_equal "trades/compact_trade", trade_options[:partial]
    assert_not trade_options[:locals][:in_split_group]

    valuation = entries(:valuation)
    valuation_options = compact_entry_render_options(valuation, flat: true, hide_balance: true)
    assert_equal "valuations/compact_valuation", valuation_options[:partial]
    assert_equal({ entry: valuation, running_balance: nil, hide_balance: true, flat: true }, valuation_options[:locals])
  end

  test "compact_row_context_fields renders both context inputs without ids" do
    @view_ctx = "account"
    @is_filtered = false

    html = compact_row_context_fields

    assert_match(/name="view_ctx"/, html)
    assert_match(/value="account"/, html)
    assert_match(/name="is_filtered"/, html)
    assert_match(/value="0"/, html)
    assert_no_match(/id=/, html)
  end

  test "compact_row_context_fields defaults to global and unfiltered" do
    @view_ctx = nil
    @is_filtered = nil

    html = compact_row_context_fields

    assert_match(/name="view_ctx"/, html)
    assert_match(/value="global"/, html)
    assert_match(/name="is_filtered"/, html)
    assert_match(/value="0"/, html)
  end

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
