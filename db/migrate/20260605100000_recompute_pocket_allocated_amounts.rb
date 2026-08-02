class RecomputePocketAllocatedAmounts < ActiveRecord::Migration[7.2]
  def up
    Pocket.where.not(tag_id: nil).find_each(&:recompute_from_tag!)
  end

  def down
    # Not reversible — there is no way to restore previous (potentially incorrect) values
  end
end
