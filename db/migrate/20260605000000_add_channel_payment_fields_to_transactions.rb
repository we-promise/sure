# frozen_string_literal: true

class AddChannelPaymentFieldsToTransactions < ActiveRecord::Migration[7.1]
  def change
    add_column :transactions, :channel, :string
    add_column :transactions, :channel_payment, :boolean, default: false, null: false
    add_column :transactions, :channel_record, :boolean, default: false, null: false
    add_reference :transactions, :channel_record_parent,
                  foreign_key: { to_table: :transactions },
                  type: :uuid
  end
end
