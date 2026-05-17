class AddStartDateToLoans < ActiveRecord::Migration[7.2]
  def up
    add_column :loans, :start_date, :date
    execute <<~SQL.squish
      UPDATE loans
      SET start_date = COALESCE(created_at::date, CURRENT_DATE)
      WHERE start_date IS NULL
    SQL
  end

  def down
    remove_column :loans, :start_date
  end
end
