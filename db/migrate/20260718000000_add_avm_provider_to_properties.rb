class AddAvmProviderToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :avm_provider, :string
    add_column :properties, :avm_last_synced_on, :date
  end
end
