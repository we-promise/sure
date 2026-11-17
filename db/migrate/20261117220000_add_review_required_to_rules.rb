# A rule whose author is gone (their user was removed, or their import
# session lost its creator) waits for an admin to switch it on before any
# run uses it, Apply all included.
class AddReviewRequiredToRules < ActiveRecord::Migration[8.1]
  def change
    add_column :rules, :review_required, :boolean, default: false, null: false
  end
end
