# Records the TOTP time step a user last signed in with, so the same code
# cannot be accepted a second time while it is still valid.
class AddOtpLastUsedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :otp_last_used_at, :datetime
  end
end
