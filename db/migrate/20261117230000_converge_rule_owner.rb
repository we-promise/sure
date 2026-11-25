# Installs that ran an earlier version of 20261117190000 and 20261117220000
# have rules.restricted_to_id and rules.review_required instead of
# rules.user_id. The restricted user becomes the rule's owner, which keeps
# what the rule may change, and the review flag goes. Fresh installs already
# have rules.user_id, so this does nothing there.
class ConvergeRuleOwner < ActiveRecord::Migration[8.1]
  def up
    if column_exists?(:rules, :restricted_to_id)
      unless column_exists?(:rules, :user_id)
        add_reference :rules, :user, type: :uuid, foreign_key: true, index: true
      end
      execute "UPDATE rules SET user_id = restricted_to_id WHERE user_id IS NULL AND restricted_to_id IS NOT NULL"
      remove_reference :rules, :restricted_to, type: :uuid, foreign_key: { to_table: :users }, index: true
    end

    remove_column :rules, :review_required if column_exists?(:rules, :review_required)
  end

  def down
  end
end
