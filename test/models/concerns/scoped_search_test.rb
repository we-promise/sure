require "test_helper"

class ScopedSearchTest < ActiveSupport::TestCase
  class AccountSearch
    include ScopedSearch

    attribute :currency, :string
    attribute :include_disabled, :boolean

    def accounts_scope
      relation = scope
      relation = relation.where(currency: currency.upcase) unless currency.nil?
      relation = relation.where.not(status: "disabled") unless include_disabled
      relation
    end
  end

  setup do
    @family = families(:dylan_family)
    @scope = @family.accounts
  end

  test "filters start off and leave the authorised scope as it is" do
    search = AccountSearch.new(@scope)

    assert_nil search.currency
    assert_equal @scope.where.not(status: "disabled").to_a.sort_by(&:id), search.accounts_scope.to_a.sort_by(&:id)
  end

  test "filters are typed attributes applied on top of the scope" do
    account = @scope.first

    search = AccountSearch.new(@scope, filters: { currency: account.currency.downcase, include_disabled: true })

    assert_equal true, search.include_disabled
    assert_includes search.accounts_scope, account
    assert search.accounts_scope.all? { |result| result.family_id == @family.id && result.currency == account.currency }
  end

  test "never widens the scope it is given" do
    other = accounts(:depository)
    narrowed = @scope.where.not(id: other.id)

    assert_not_includes AccountSearch.new(narrowed, filters: { include_disabled: true }).accounts_scope, other
  end

  test "rejects a filter it does not declare" do
    assert_raises(ActiveModel::UnknownAttributeError) { AccountSearch.new(@scope, filters: { colour: "red" }) }
  end
end
