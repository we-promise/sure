class AddProgressBasisToGoals < ActiveRecord::Migration[7.2]
  def change
    # How a goal measures progress:
    # - "balance"       : live account balance (market value for investment
    #                     accounts) — the v1 behaviour, the default.
    # - "contributions" : net money put in, excluding market gains/losses
    #                     (balances.net_market_flows) — the default for goals
    #                     funded by investment accounts so a market swing
    #                     doesn't move the goal.
    add_column :goals, :progress_basis, :string, null: false, default: "balance"

    add_check_constraint :goals,
                         "progress_basis IN ('balance','contributions')",
                         name: "chk_goals_progress_basis_enum"
  end
end
