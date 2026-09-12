require "test_helper"

class ValuationTest < ActiveSupport::TestCase
  test "localizes generated valuation names when rendering" do
    entry = Entry.new(name: "Manual value update", account: accounts(:investment))
    valuation = Valuation.new(kind: "reconciliation")

    I18n.with_locale(:fr) do
      assert_equal "Mise à jour manuelle de la valeur", valuation.display_name(entry)
    end
  end

  test "preserves custom valuation names when rendering" do
    entry = Entry.new(name: "Réévaluation annuelle", account: accounts(:investment))
    valuation = Valuation.new(kind: "reconciliation")

    assert_equal "Réévaluation annuelle", valuation.display_name(entry)
  end
end
