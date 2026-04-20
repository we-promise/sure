class FixBondLotsNonInflationCheckConstraint < ActiveRecord::Migration[7.2]
  # No-op migration: the target check expression already matches
  # 20260331120000_create_bond_lots.rb in this branch.
  # Keeping this migration inert avoids unnecessary constraint drop/re-add locks.
  def up; end

  # No-op rollback for symmetry with the no-op up.
  def down; end
end
