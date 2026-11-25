require "test_helper"

class Account::SearchTest < ActiveSupport::TestCase
  setup do
    @scope = families(:dylan_family).accounts
    @disabled = accounts(:depository)
    @disabled.disable!
  end

  test "hides disabled accounts unless include_disabled is true" do
    assert_not_includes Account::Search.new(@scope).accounts_scope, @disabled
    assert_not_includes Account::Search.new(@scope, filters: { include_disabled: false }).accounts_scope, @disabled
    assert_includes Account::Search.new(@scope, filters: { include_disabled: true }).accounts_scope, @disabled
  end

  test "never widens the scope it is given" do
    narrowed = @scope.where.not(id: @disabled.id)

    assert_not_includes Account::Search.new(narrowed, filters: { include_disabled: true }).accounts_scope, @disabled
  end
end
