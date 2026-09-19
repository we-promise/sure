# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260916120000_add_classification_to_securities")

# The migration declares `disable_ddl_transaction!`, so each statement commits on
# its own while the schema_migrations row stays unwritten. A process killed
# part-way therefore leaves the schema partly changed and the migration still
# pending, and the next run has to finish the job rather than die on something it
# already did. These tests pin that promise for the two states such a run can
# find a check constraint in: already validated, and added but NOT VALID.
class AddClassificationToSecuritiesMigrationTest < ActiveSupport::TestCase
  CONSTRAINT = "chk_securities_asset_class"

  # The state every existing installation is already in: the columns and the
  # constraints are present and validated, because this migration -- or the
  # fork's earlier copy of it, which this one replaces -- has run to completion.
  #
  # `if_not_exists: true` does NOT cover this. It resolves through
  # `CheckConstraintDefinition#defined_for?`, which compares `validate` next to
  # the name, so it only recognises a constraint that is also NOT VALID. Against
  # a validated one it reports "absent", the ADD is issued a second time and
  # PostgreSQL raises PG::DuplicateObject. Without the name-only guard in `up`,
  # this test fails with exactly that error.
  test "re-running over validated constraints does not raise" do
    assert constraint_validated?, "fixture schema should already carry the validated constraint"

    assert_nothing_raised { run_migration }

    assert constraint_validated?, "the constraint must still be present and validated afterwards"
  end

  # The other half of the boundary, and the case the original `if_not_exists:`
  # was aimed at: killed after the ADD but before the VALIDATE. The re-run must
  # not duplicate the constraint, and must finish the validation it skipped.
  test "re-running over an unvalidated constraint validates it rather than duplicating it" do
    # The predicate an interrupted run would actually have left: the migration
    # adds the full list NOT VALID and validates it afterwards, so a process
    # killed in between leaves THIS, not some narrower constraint. Built from
    # the migration's own constant so the two cannot drift.
    values = AddClassificationToSecurities::ASSET_CLASSES.map { |v| "'#{v}'" }.join(", ")
    connection.execute("ALTER TABLE securities DROP CONSTRAINT #{CONSTRAINT}")
    connection.execute(
      "ALTER TABLE securities ADD CONSTRAINT #{CONSTRAINT} " \
      "CHECK (asset_class IN (#{values})) NOT VALID"
    )
    assert_not constraint_validated?, "precondition: the constraint is present but NOT VALID"

    assert_nothing_raised { run_migration }

    assert_equal 1, constraint_count, "the re-run must not add a second constraint under the same name"
    assert constraint_validated?, "the re-run must validate the constraint it found unvalidated"
  end

  private
    def connection = ActiveRecord::Base.connection

    def constraint_count
      connection.select_value(
        "SELECT count(*) FROM pg_constraint WHERE conname = #{connection.quote(CONSTRAINT)}"
      )
    end

    def constraint_validated?
      connection.select_value(
        "SELECT convalidated FROM pg_constraint WHERE conname = #{connection.quote(CONSTRAINT)}"
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        AddClassificationToSecurities.new.up
      end
    end
end
