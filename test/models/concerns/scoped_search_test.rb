require "test_helper"

class ScopedSearchTest < ActiveSupport::TestCase
  class AccountSearch
    include ScopedSearch

    attribute :currency, :string
    attribute :include_disabled, :boolean
    attribute :created_from, :datetime
    attribute :created_until, :datetime

    def accounts_scope
      relation = scope
      relation = relation.where(currency: currency.upcase) unless currency.nil?
      relation = relation.where.not(status: "disabled") unless include_disabled
      within_range(relation, :created_at, created_from, created_until)
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

  test "within_range bounds a column inclusively at either end, or both" do
    old, recent = @scope.order(:created_at).first(2)
    old.update_columns(created_at: 3.days.ago)
    recent.update_columns(created_at: 1.day.ago)

    from_recent = AccountSearch.new(@scope, filters: { include_disabled: true, created_from: recent.created_at }).accounts_scope
    until_old = AccountSearch.new(@scope, filters: { include_disabled: true, created_until: old.created_at }).accounts_scope
    only_old = AccountSearch.new(@scope, filters: { include_disabled: true, created_from: old.created_at, created_until: 2.days.ago }).accounts_scope

    assert_includes from_recent, recent
    assert_not_includes from_recent, old
    assert_includes until_old, old
    assert_not_includes until_old, recent
    assert_equal [ old ], only_old.to_a
  end

  test "within_range with neither bound leaves the relation as it is" do
    relation = @scope.where.not(status: "disabled")

    assert_equal relation.to_sql, AccountSearch.new(@scope).accounts_scope.to_sql
  end

  test "rejects a filter it does not declare" do
    assert_raises(ActiveModel::UnknownAttributeError) { AccountSearch.new(@scope, filters: { colour: "red" }) }
  end
end
