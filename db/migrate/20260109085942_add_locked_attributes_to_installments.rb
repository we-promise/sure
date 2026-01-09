class AddLockedAttributesToInstallments < ActiveRecord::Migration[7.2]
  def change
    add_column :installments, :locked_attributes, :jsonb, default: {}
  end
end
