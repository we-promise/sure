require "test_helper"

class SimplefinItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Importer Test",
      access_url: "https://example.com/access"
    )
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
  end

  test "normalizes numeric-string epoch balance-date for importer upserts" do
    epoch_string = Time.utc(2026, 6, 17, 12, 34, 56).to_i.to_s

    parsed = @importer.send(:normalize_balance_date, epoch_string)

    assert_equal Time.at(epoch_string.to_i).utc, parsed
  end
end
