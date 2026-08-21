class AddOriginalKindToEmiPlans < ActiveRecord::Migration[7.2]
  def change
    # Records the Transaction#kind the parent entry had immediately before
    # conversion to an EMI plan (always "standard" going forward, since
    # emi_convertible? now requires that -- see Transaction::Splittable).
    # EmiPlan#build! writes it, and EmiPlan#foreclose! reads it back to
    # restore the exact original kind instead of hard-coding "standard",
    # so a plan built on a not-yet-"standard" historical row (from before
    # this constraint existed) still unwinds correctly on foreclosure.
    add_column :emi_plans, :original_kind, :string, null: false, default: "standard"
  end
end
