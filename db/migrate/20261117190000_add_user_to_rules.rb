# The person a rule acts for: it changes only transactions in accounts its
# owner may change. Rules without one act on the whole family.
class AddUserToRules < ActiveRecord::Migration[8.1]
  def change
    add_reference :rules, :user, type: :uuid, foreign_key: true, index: true
  end
end
