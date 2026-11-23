class RemoveIndexesCoveredByMultiColumnIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # all of these indexes are redundant since they're also the first column in a different multi-column index
  def change
    remove_index :account_shares, [ "account_id" ], name: "index_account_shares_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :account_shares, [ "user_id" ], name: "index_account_shares_on_user_id", algorithm: :concurrently, if_exists: true
    remove_index :account_statements, [ "account_id" ], name: "index_account_statements_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :account_statements, [ "family_id" ], name: "index_account_statements_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :account_statements, [ "suggested_account_id" ], name: "index_account_statements_on_suggested_account_id", algorithm: :concurrently, if_exists: true
    remove_index :accounts, [ "family_id" ], name: "index_accounts_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :accounts, [ "family_id", "status" ], name: "index_accounts_on_family_id_and_status", algorithm: :concurrently, if_exists: true
    remove_index :api_keys, [ "user_id" ], name: "index_api_keys_on_user_id", algorithm: :concurrently, if_exists: true
    remove_index :balances, [ "account_id" ], name: "index_balances_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :binance_accounts, [ "binance_item_id" ], name: "index_binance_accounts_on_binance_item_id", algorithm: :concurrently, if_exists: true
    remove_index :brex_accounts, [ "brex_item_id" ], name: "index_brex_accounts_on_brex_item_id", algorithm: :concurrently, if_exists: true
    remove_index :budget_categories, [ "budget_id" ], name: "index_budget_categories_on_budget_id", algorithm: :concurrently, if_exists: true
    remove_index :budget_shares, [ "owner_id" ], name: "index_budget_shares_on_owner_id", algorithm: :concurrently, if_exists: true
    remove_index :categories, [ "family_id" ], name: "index_categories_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :categorization_comparisons, [ "family_id" ], name: "index_categorization_comparisons_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :coinspot_accounts, [ "coinspot_item_id" ], name: "index_coinspot_accounts_on_coinspot_item_id", algorithm: :concurrently, if_exists: true
    remove_index :coinstats_accounts, [ "coinstats_item_id" ], name: "index_coinstats_accounts_on_coinstats_item_id", algorithm: :concurrently, if_exists: true
    remove_index :debug_log_entries, [ "category" ], name: "index_debug_log_entries_on_category", algorithm: :concurrently, if_exists: true
    remove_index :debug_log_entries, [ "provider_key" ], name: "index_debug_log_entries_on_provider_key", algorithm: :concurrently, if_exists: true
    remove_index :entries, [ "account_id" ], name: "index_entries_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :eval_results, [ "eval_run_id" ], name: "index_eval_results_on_eval_run_id", algorithm: :concurrently, if_exists: true
    remove_index :eval_runs, [ "eval_dataset_id" ], name: "index_eval_runs_on_eval_dataset_id", algorithm: :concurrently, if_exists: true
    remove_index :eval_samples, [ "eval_dataset_id" ], name: "index_eval_samples_on_eval_dataset_id", algorithm: :concurrently, if_exists: true
    remove_index :exchange_rates, [ "from_currency" ], name: "index_exchange_rates_on_from_currency", algorithm: :concurrently, if_exists: true
    remove_index :family_merchant_associations, [ "family_id" ], name: "index_family_merchant_associations_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :financekit_accounts, [ "financekit_item_id" ], name: "index_financekit_accounts_on_financekit_item_id", algorithm: :concurrently, if_exists: true
    remove_index :financekit_balance_observations, [ "financekit_account_lineage_id" ], name: "index_financekit_balances_on_lineage_id", algorithm: :concurrently, if_exists: true
    remove_index :financekit_batches, [ "financekit_item_id" ], name: "index_financekit_batches_on_financekit_item_id", algorithm: :concurrently, if_exists: true
    remove_index :financekit_conflicts, [ "financekit_item_id" ], name: "index_financekit_conflicts_on_financekit_item_id", algorithm: :concurrently, if_exists: true
    remove_index :financekit_items, [ "family_id" ], name: "index_financekit_items_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :financekit_transactions, [ "financekit_account_lineage_id" ], name: "index_financekit_transactions_on_lineage_id", algorithm: :concurrently, if_exists: true
    remove_index :goal_accounts, [ "goal_id" ], name: "index_goal_accounts_on_goal_id", algorithm: :concurrently, if_exists: true
    remove_index :goal_pledges, [ "goal_id" ], name: "index_goal_pledges_on_goal_id", algorithm: :concurrently, if_exists: true
    remove_index :goals, [ "family_id" ], name: "index_goals_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :holdings, [ "account_id" ], name: "index_holdings_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :import_rows, [ "import_id" ], name: "index_import_rows_on_import_id", algorithm: :concurrently, if_exists: true
    remove_index :import_sessions, [ "family_id" ], name: "index_import_sessions_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :import_source_mappings, [ "family_id" ], name: "index_import_source_mappings_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :import_source_mappings, [ "import_session_id" ], name: "index_import_source_mappings_on_import_session_id", algorithm: :concurrently, if_exists: true
    remove_index :kraken_accounts, [ "kraken_item_id" ], name: "index_kraken_accounts_on_kraken_item_id", algorithm: :concurrently, if_exists: true
    remove_index :llm_usages, [ "family_id" ], name: "index_llm_usages_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :mercury_accounts, [ "mercury_item_id" ], name: "index_mercury_accounts_on_mercury_item_id", algorithm: :concurrently, if_exists: true
    remove_index :mobile_devices, [ "user_id" ], name: "index_mobile_devices_on_user_id", algorithm: :concurrently, if_exists: true
    remove_index :notification_deliveries, [ "rule_id" ], name: "index_notification_deliveries_on_rule_id", algorithm: :concurrently, if_exists: true
    remove_index :onchain_wallet_accounts, [ "onchain_wallet_item_id" ], name: "index_onchain_wallet_accounts_on_onchain_wallet_item_id", algorithm: :concurrently, if_exists: true
    remove_index :plaid_accounts, [ "plaid_item_id" ], name: "index_plaid_accounts_on_plaid_item_id", algorithm: :concurrently, if_exists: true
    remove_index :questrade_accounts, [ "questrade_item_id" ], name: "index_questrade_accounts_on_questrade_item_id", algorithm: :concurrently, if_exists: true
    remove_index :recurring_transactions, [ "family_id" ], name: "index_recurring_transactions_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :redbark_accounts, [ "redbark_item_id" ], name: "index_redbark_accounts_on_redbark_item_id", algorithm: :concurrently, if_exists: true
    remove_index :rejected_transfers, [ "inflow_transaction_id" ], name: "index_rejected_transfers_on_inflow_transaction_id", algorithm: :concurrently, if_exists: true
    remove_index :rule_groups, [ "family_id" ], name: "index_rule_groups_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :rule_runs, [ "rule_id" ], name: "index_rule_runs_on_rule_id", algorithm: :concurrently, if_exists: true
    remove_index :rules, [ "family_id" ], name: "index_rules_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :securities, [ "price_provider" ], name: "index_securities_on_price_provider", algorithm: :concurrently, if_exists: true
    remove_index :security_audit_logs, [ "user_id" ], name: "index_security_audit_logs_on_user_id", algorithm: :concurrently, if_exists: true
    remove_index :security_prices, [ "security_id" ], name: "index_security_prices_on_security_id", algorithm: :concurrently, if_exists: true
    remove_index :security_splits, [ "security_id" ], name: "index_security_splits_on_security_id", algorithm: :concurrently, if_exists: true
    remove_index :sophtron_accounts, [ "sophtron_item_id" ], name: "index_sophtron_accounts_on_sophtron_item_id", algorithm: :concurrently, if_exists: true
    remove_index :sso_audit_logs, [ "user_id" ], name: "index_sso_audit_logs_on_user_id", algorithm: :concurrently, if_exists: true
    remove_index :syncs, [ "syncable_type", "syncable_id" ], name: "index_syncs_on_syncable", algorithm: :concurrently, if_exists: true
    remove_index :tags, [ "family_id" ], name: "index_tags_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :trade_republic_accounts, [ "trade_republic_item_id" ], name: "index_trade_republic_accounts_on_trade_republic_item_id", algorithm: :concurrently, if_exists: true
    remove_index :transfers, [ "inflow_transaction_id" ], name: "index_transfers_on_inflow_transaction_id", algorithm: :concurrently, if_exists: true
    remove_index :weekly_cleanup_runs, [ "family_id" ], name: "index_weekly_cleanup_runs_on_family_id", algorithm: :concurrently, if_exists: true
    remove_index :wise_accounts, [ "wise_item_id" ], name: "index_wise_accounts_on_wise_item_id", algorithm: :concurrently, if_exists: true
    remove_index :wise_items, [ "family_id" ], name: "index_wise_items_on_family_id", algorithm: :concurrently, if_exists: true
  end
end
