# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261106140000_move_categorization_provider_to_setting")

# The Jev choice moves from the family to the instance. The test schema
# already lacks the column, so each test puts it back with `down`, sets the families' choices,
# and runs `up`.
class MoveCategorizationProviderToSettingMigrationTest < ActiveSupport::TestCase
  setup do
    @migration = MoveCategorizationProviderToSetting.new
    migrate(:down)
  end

  teardown do
    Setting.categorization_provider = nil
    Family.reset_column_information
  end

  def migrate(direction) = ActiveRecord::Migration.suppress_messages { @migration.public_send(direction) }

  def choose!(provider, family = families(:dylan_family))
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([ "UPDATE families SET categorization_provider = ? WHERE id = ?", provider, family.id ]))
  end

  def column? = ActiveRecord::Base.connection.column_exists?(:families, :categorization_provider)

  test "an instance with one family keeps its Jev choice" do
    choose!("jev")
    @migration.stubs(:select_values).returns([ "jev" ])

    migrate(:up)

    assert_equal "jev", Setting.categorization_provider
    assert_not column?
  end

  test "an instance with one family on the LLM copies nothing" do
    @migration.stubs(:select_values).returns([ "llm" ])

    migrate(:up)

    assert_nil Setting.categorization_provider
  end

  test "an instance with several families copies nothing, even when one chose Jev" do
    choose!("jev")
    assert_operator Family.count, :>, 1

    migrate(:up)

    assert_nil Setting.categorization_provider
    assert_not column?
  end

  test "an existing setting is kept" do
    Setting.categorization_provider = "llm"
    @migration.stubs(:select_values).returns([ "jev" ])

    migrate(:up)

    assert_equal "llm", Setting.categorization_provider
  end

  test "down restores the column, and a single family's Jev choice" do
    migrate(:up)
    Setting.categorization_provider = "jev"
    @migration.stubs(:select_value).with("SELECT count(*) FROM families").returns(1)
    @migration.stubs(:select_value).with("SELECT value FROM settings WHERE var = 'categorization_provider'").returns("--- jev\n")

    migrate(:down)

    assert column?
    assert_equal [ "jev" ], ActiveRecord::Base.connection.select_values("SELECT DISTINCT categorization_provider FROM families")
  end
end
