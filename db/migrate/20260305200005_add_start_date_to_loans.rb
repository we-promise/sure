class AddStartDateToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :start_date, :date
    # Backfill required before enforcing NOT NULL at DB level.
    # Model validates presence only on: :create, but direct writes bypass Rails.
    execute <<~SQL.squish
      UPDATE loans
      SET start_date = COALESCE(created_at::date, CURRENT_DATE)
      WHERE start_date IS NULL
    SQL

    change_column_null :loans, :start_date, false
  end

  def down
    remove_column :loans, :start_date
  end
end
