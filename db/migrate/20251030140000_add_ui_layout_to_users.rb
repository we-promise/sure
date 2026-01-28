class AddUiLayoutToUsers < ActiveRecord::Migration[7.2]
  class MigrationUser < ApplicationRecord
    self.table_name = "users"
  end

  def up
    add_column :users, :ui_layout, :string, if_not_exists: true

    MigrationUser.reset_column_information
    MigrationUser.where(ui_layout: [ nil, "" ]).update_all(ui_layout: "dashboard")
  end

  def down
    remove_column :users, :ui_layout
  end
end
