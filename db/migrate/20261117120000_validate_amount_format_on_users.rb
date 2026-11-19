class ValidateAmountFormatOnUsers < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :users, name: "chk_users_amount_format"
  end
end
