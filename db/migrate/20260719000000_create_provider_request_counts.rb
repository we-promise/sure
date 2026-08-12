class CreateProviderRequestCounts < ActiveRecord::Migration[7.2]
  def change
    create_table :provider_request_counts, id: :uuid do |t|
      t.string :provider_key, null: false
      t.string :period, null: false
      t.integer :count, null: false, default: 0

      t.timestamps
    end

    add_index :provider_request_counts, [ :provider_key, :period ], unique: true
  end
end
