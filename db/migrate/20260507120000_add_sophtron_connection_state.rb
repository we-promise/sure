class AddSophtronConnectionState < ActiveRecord::Migration[7.2]
  def change
    change_column_null :sophtron_accounts, :customer_id, true
    change_column_null :sophtron_accounts, :member_id, true

    add_column :sophtron_accounts, :account_number_mask, :string

    add_column :sophtron_items, :customer_id, :string
    add_column :sophtron_items, :customer_name, :string
    add_column :sophtron_items, :raw_customer_payload, :jsonb
    add_column :sophtron_items, :user_institution_id, :string
    add_column :sophtron_items, :current_job_id, :string
    add_column :sophtron_items, :job_status, :string
    add_column :sophtron_items, :raw_job_payload, :jsonb
    add_column :sophtron_items, :last_connection_error, :text

    add_index :sophtron_items, :customer_id
    add_index :sophtron_items, :user_institution_id
  end
end
