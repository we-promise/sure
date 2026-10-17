class AllowFinecoSessionClearing < ActiveRecord::Migration[8.1]
  def change
    change_column_null :fineco_items, :gsessionid, true
  end
end
