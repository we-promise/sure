class AddPledgeIdIndexToTransactions < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :transactions,
              "((extra -> 'goal' ->> 'pledge_id'))",
              unique: true,
              where: "(extra -> 'goal' ->> 'pledge_id') IS NOT NULL",
              name: "ix_transactions_extra_goal_pledge_id",
              algorithm: :concurrently
  end
end
