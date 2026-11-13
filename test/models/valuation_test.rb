require "test_helper"

class ValuationTest < ActiveSupport::TestCase
  test "localizes generated valuation names when rendering" do
    entry = Entry.new(name: "Manual value update", account: accounts(:investment))
    valuation = Valuation.new(kind: "reconciliation")

    I18n.with_locale(:fr) do
      assert_equal "Mise à jour manuelle de la valeur", valuation.display_name(entry)
    end
  end

  test "names a reconciliation on a linked account after the sync that left it" do
    entry = Entry.new(name: "Manual balance update", account: accounts(:connected))
    valuation = Valuation.new(kind: "reconciliation")

    assert_equal "Synced balance", valuation.display_name(entry)
    I18n.with_locale(:fr) do
      assert_equal "Solde synchronisé", valuation.display_name(entry)
    end
  end

  test "keeps the manual name on a manual account and the anchor names on a linked one" do
    assert_equal "Manual balance update",
      Valuation.new(kind: "reconciliation").display_name(Entry.new(name: "Manual balance update", account: accounts(:depository)))
    assert_equal "Current balance",
      Valuation.new(kind: "current_anchor").display_name(Entry.new(name: "Current balance", account: accounts(:connected)))
  end

  test "preserves custom valuation names when rendering" do
    entry = Entry.new(name: "Réévaluation annuelle", account: accounts(:investment))
    valuation = Valuation.new(kind: "reconciliation")

    assert_equal "Réévaluation annuelle", valuation.display_name(entry)
  end

  test "uses the existing localized opening balance when the new name is unavailable" do
    entry = Entry.new(name: "Opening balance", account: accounts(:depository))
    valuation = Valuation.new(kind: "opening_anchor")

    I18n.with_locale(:de) do
      assert_equal "Eröffnungssaldo", valuation.display_name(entry)
    end
  end
end
