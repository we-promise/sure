class AddSignupCountersToInviteCodes < ActiveRecord::Migration[7.2]
  def change
    add_column :invite_codes, :signup_attempts_count, :integer, default: 0, null: false
    add_column :invite_codes, :successful_signups_count, :integer, default: 0, null: false
  end
end
