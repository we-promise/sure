require "test_helper"

class NameSortKeyTest < ActiveSupport::TestCase
  test "sets case and accent marks aside" do
    assert_equal "epargne", NameSortKey.for("Épargne")
    assert_equal "acme", NameSortKey.for("ACME")
    assert_equal "viet", NameSortKey.for("Việt"), "a letter with two marks loses both"
  end

  # Letters with no decomposition are spelled out in Latin letters, so they
  # sort with the letters they are written as, not after "z".
  test "spells out the letters decomposition leaves whole" do
    { "Æble" => "aeble", "Œuvre" => "oeuvre", "Øre" => "ore", "Straße" => "strasse",
      "Łódź" => "lodz", "Đakovo" => "dakovo", "Þór" => "thor", "Iğdır" => "igdir",
      "Ħamrun" => "hamrun", "Ŧ" => "t", "Ŋ" => "n", "ĸ" => "k" }.each do |name, key|
      assert_equal key, NameSortKey.for(name), name
    end
  end

  test "keeps a name with no Latin form" do
    assert_equal "甲乙", NameSortKey.for("甲乙")
  end

  # A mark in another script can make a different letter: が is not か.
  test "keeps marks that are not on a Latin letter" do
    assert_not_equal NameSortKey.for("か"), NameSortKey.for("が")
    assert_operator NameSortKey.for("か"), :<, NameSortKey.for("が")
    assert_operator NameSortKey.for("が"), :<, NameSortKey.for("き")
  end

  test "reads a missing name as empty" do
    assert_equal "", NameSortKey.for(nil)
  end
end
