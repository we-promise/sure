require "test_helper"

class Entry::NameSuggestionsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create! name: "Test", balance: 0, currency: "USD", accountable: Depository.new
  end

  test "returns case-insensitive deduped names using preferred casing variant" do
    create_transaction(account: @account, name: "Sample Vendor")
    create_transaction(account: @account, name: "sample vendor")
    create_transaction(account: @account, name: "Sample Vendor")

    suggestions = suggestions_for("sample")

    assert_equal 1, suggestions.count { |name| name.downcase == "sample vendor" }
    assert_includes suggestions, "Sample Vendor"
  end

  test "prioritizes exact then prefix matches before substring matches" do
    create_transaction(account: @account, name: "Cost")
    create_transaction(account: @account, name: "Cost Center")
    create_transaction(account: @account, name: "Warehouse Cost")

    assert_equal [ "Cost", "Cost Center", "Warehouse Cost" ], suggestions_for("cost").first(3)
  end

  test "keeps exact matches ahead of many newer substring matches" do
    create_transaction(account: @account, name: "Cost")

    501.times do |index|
      create_transaction(account: @account, name: "Miscost Example #{index}")
    end

    assert_equal "Cost", suggestions_for("cost").first
  end

  test "returns empty for very short queries" do
    assert_equal [], suggestions_for("c")
  end

  private
    def suggestions_for(query)
      Entry::NameSuggestions.new(scope: @family.entries, query: query).call
    end
end
