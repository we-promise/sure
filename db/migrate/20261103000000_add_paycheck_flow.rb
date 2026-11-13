# frozen_string_literal: true

# Consolidated paycheck-flow data model: the 12 incremental paycheck-flow
# migrations (20261026100000-20261102100000) folded into one atomic
# migration. Each section below is the verbatim DDL body of the original
# file; the up sections run in the original timestamp (dependency) order,
# the down sections in reverse. Original files (superseded):
#
#   20261026100000_create_income_account_allocations.rb
#   20261026100001_add_plan_fields_to_accounts.rb
#   20261026100002_create_family_plan_settings.rb
#   20261028000000_add_plan_owner_user_id_to_recurring_transactions.rb
#   20261029100000_create_plan_allocations.rb
#   20261029100001_add_plan_role_and_auto_transfer_to_accounts.rb
#   20261029100002_add_plan_max_account_links_to_recurring_transactions.rb
#   20261030220000_make_plan_allocation_account_nullable.rb
#   20261101100000_add_plan_sub_accounts.rb
#   20261101110000_add_category_id_to_plan_allocations.rb
#   20261101130000_add_bank_logo_slug_to_accounts.rb
#   20261102100000_extend_plan_role_check_constraint.rb

class AddPaycheckFlow < ActiveRecord::Migration[8.1]
  def up
    # 20261026100000_create_income_account_allocations
    # account, with the per-edge mode. `value` is the per-paycheck amount (major
    # units) for `specific` and the 0.0-1.0 fraction for `percent`; it must stay
    # NULL for `required` and `leftover`, which are derived at solve time.
    create_table :income_account_allocations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :family_id, null: false
      t.uuid :income_series_id, null: false
      t.uuid :account_id, null: false
      t.string :mode, null: false
      t.decimal :value, precision: 12, scale: 6
      t.integer :sort_index
      t.timestamps null: false
    end

    add_index :income_account_allocations, [ :income_series_id, :account_id ], unique: true
    add_index :income_account_allocations, :family_id
    add_index :income_account_allocations, :account_id
    add_check_constraint :income_account_allocations,
                         "mode::text = ANY (ARRAY['required'::text, 'specific'::text, 'percent'::text, 'leftover'::text])",
                         name: "chk_income_account_allocations_mode"
    add_check_constraint :income_account_allocations,
                         "(mode = 'specific' AND value > 0) OR (mode = 'percent' AND value > 0 AND value <= 1) OR (mode IN ('required', 'leftover') AND value IS NULL)",
                         name: "chk_income_account_allocations_value_mode"

    # 20261026100001_add_plan_fields_to_accounts
    # `plan_ownership` picks whether an account is Home/Shared or belongs to one
    # family member (drives Sankey color and attribution); `plan_owner_user_id`
    # names that member; `plan_order` is the center-column ordering.
    add_column :accounts, :plan_ownership, :string, default: "shared", null: false
    add_column :accounts, :plan_owner_user_id, :uuid
    add_column :accounts, :plan_order, :integer

    add_index :accounts, :plan_owner_user_id
    add_check_constraint :accounts,
                         "plan_ownership::text = ANY (ARRAY['shared'::text, 'user'::text])",
                         name: "chk_accounts_plan_ownership"
    add_check_constraint :accounts,
                         "(plan_ownership = 'shared' AND plan_owner_user_id IS NULL) OR plan_owner_user_id IS NOT NULL",
                         name: "chk_accounts_plan_owner_consistency"

    # 20261026100002_create_family_plan_settings
    # attributed between partners. `income_ratio` splits by each partner's share
    # of total income, `equal_split` 1/N, `custom` is v2 (its rules live in
    # `custom_rules`).
    create_table :family_plan_settings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :family_id, null: false
      t.string :leftover_distribution, default: "income_ratio", null: false
      t.jsonb :custom_rules
      t.timestamps null: false
    end

    add_index :family_plan_settings, :family_id, unique: true
    add_check_constraint :family_plan_settings,
                         "leftover_distribution::text = ANY (ARRAY['income_ratio'::text, 'equal_split'::text, 'custom'::text])",
                         name: "chk_family_plan_settings_leftover_distribution"

    # 20261028000000_add_plan_owner_user_id_to_recurring_transactions
    # recurring transaction has no owner column of its own; the flow planner falls
    # back to the landing account's owner. `plan_owner_user_id` is the explicit
    # s3 attribution note). NULL keeps the account-owner fallback.
    add_column :recurring_transactions, :plan_owner_user_id, :uuid
    add_index :recurring_transactions, :plan_owner_user_id

    # 20261029100000_create_plan_allocations
    #
    # A PlanAllocation is one item pulled out of a source bank on the family's
    # planning diagram -- a bill, debt payment, savings target, or fun money --
    # with the rule that decides how much it gets per paycheck (mode + value).
    # The bank-level resolution order is fixed (required -> specific -> percent
    # of the leftover pool -> leftover split equally); see PaycheckFlowPlanner#plan_graph.
    create_table :plan_allocations, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid :family_id, null: false
      # The source bank the money is pulled from (the diagram's "SOURCE BANK").
      t.uuid :account_id, null: false
      t.string :name, null: false
      t.string :kind, null: false
      t.string :mode, null: false
      # Mode-specific value, integer cents as 2-dp decimal (house Money
      # convention: cents internally, 2dp major units for display).
      # required (explicit amount) | specific (per-paycheck hard number).
      t.decimal :value_cents, precision: 12, scale: 2
      # percent mode: 0 < value <= 1, a share of the bank's leftover pool.
      t.decimal :value_percent
      # weekly | biweekly | monthly | quarterly | yearly; autofilled from the
      # linked recurring transaction's interval/weekday, editable.
      t.string :cadence
      # The detected bill/debt this allocation represents (autofill source);
      # required mode without value_cents resolves its amount from the
      # transaction's monthly_equivalent_amount.
      t.uuid :recurring_transaction_id
      t.boolean :auto_transfer, default: false, null: false
      t.integer :sort_index
      t.timestamps null: false
    end

    add_index :plan_allocations, [ :family_id, :account_id ]
    add_index :plan_allocations, :recurring_transaction_id

    add_check_constraint :plan_allocations,
      "kind::text = ANY (ARRAY['bill'::text, 'debt'::text, 'savings'::text, 'fun_money'::text])",
      name: "chk_plan_allocations_kind"
    add_check_constraint :plan_allocations,
      "mode::text = ANY (ARRAY['required'::text, 'specific'::text, 'percent'::text, 'leftover'::text])",
      name: "chk_plan_allocations_mode"
    add_check_constraint :plan_allocations,
      "cadence IS NULL OR cadence::text = ANY (ARRAY['weekly'::text, 'biweekly'::text, 'monthly'::text, 'quarterly'::text, 'yearly'::text])",
      name: "chk_plan_allocations_cadence"
    # Value-presence per mode (the model layer enforces the same rules):
    #   required: value_cents OR a linked transaction (never both absent)
    #   specific: value_cents > 0
    #   percent:  0 < value_percent <= 1
    #   leftover: no value at all (splits the bank's final residual equally)
    add_check_constraint :plan_allocations,
      "(mode::text = 'required'::text AND value_percent IS NULL AND " \
      "(value_cents IS NOT NULL OR recurring_transaction_id IS NOT NULL) AND " \
      "(value_cents IS NULL OR value_cents > 0)) OR " \
      "(mode::text = 'specific'::text AND value_cents > 0 AND value_percent IS NULL) OR " \
      "(mode::text = 'percent'::text AND value_percent > 0 AND value_percent <= 1 AND value_cents IS NULL) OR " \
      "(mode::text = 'leftover'::text AND value_cents IS NULL AND value_percent IS NULL)",
      name: "chk_plan_allocations_value_mode"

    # 20261029100001_add_plan_role_and_auto_transfer_to_accounts
    #
    # plan_role labels an account as an allocation target on the planning
    # diagram (a SoFi autopilot savings bucket, a credit card payoff, a loan
    # payoff). Plain nullable string + a constant list in the model (kept
    # enum-safe: adding a role is a data change, not a schema change).
    #
    # auto_transfer_to_account_id: this account auto-transfers money to another
    # family account (self FK). Set = auto-transfer enabled; data only this
    # round -- the diagram shows the link, the planner does not move money
    # along it yet.
    add_column :accounts, :plan_role, :string
    add_column :accounts, :auto_transfer_to_account_id, :uuid

    add_index :accounts, :auto_transfer_to_account_id

    add_check_constraint :accounts,
      "plan_role IS NULL OR plan_role::text = ANY (ARRAY['savings_bucket'::text, 'credit_card_payoff'::text, 'loan_payoff'::text])",
      name: "chk_accounts_plan_role"

    # 20261029100002_add_plan_max_account_links_to_recurring_transactions
    #
    # plan_max_account_links caps how many bank accounts an income series may be
    # linked to (the income config dialog). NULL = unlimited. At plan time the
    # planner raises a WARNING (amber), never an error -- the owner's review
    # decision A4.
    add_column :recurring_transactions, :plan_max_account_links, :integer

    add_check_constraint :recurring_transactions,
      "plan_max_account_links IS NULL OR plan_max_account_links >= 1",
      name: "chk_recurring_transactions_plan_max_account_links"

    # 20261030220000_make_plan_allocation_account_nullable
    # keeps its allocations -- they lose their source-bank assignment (the
    # "No Assignment" marker) and persist, to be re-assigned later. The source
    # bank therefore must be optional at the schema level. No other constraint
    # touches account_id (no FK, no check constraint).
    change_column_null :plan_allocations, :account_id, true

    # 20261101100000_add_plan_sub_accounts
    #
    # parent_account_id: labels an account as a sub-account of another plan
    # bank (a bucket under the parent). Depth 1 only -- the sankey renders one
    # child column and the model validation rejects chains (the parent's own
    # parent must be nil).
    #
    # auto_transfer_target_ids: ordered array of account uuids. The source
    # auto-transfers to each target (fan-out from one bank to several
    # buckets); the array order is the band order in the diagram. Round-11
    # strict rule (model validation): each target must be a sub-account of
    # the source.
    #
    # Data step: carry the legacy single-target auto_transfer_to_account_id
    # rows into the new array (verified no-op on the dev DB: 0 rows carry the
    # legacy value; kept for prod parity). The legacy column stays one more
    # round.
    add_column :accounts, :parent_account_id, :uuid
    add_index :accounts, :parent_account_id
    add_column :accounts, :auto_transfer_target_ids, :jsonb, default: []

    execute <<-SQL
      UPDATE accounts
         SET auto_transfer_target_ids = to_jsonb(ARRAY[auto_transfer_to_account_id])
       WHERE auto_transfer_to_account_id IS NOT NULL
    SQL

    # 20261101110000_add_category_id_to_plan_allocations
    # to match the Sure category. plan_allocations had no category link, so the
    # diagram could not know which category color to use.
    #
    # Nullable FK: an allocation without a category renders with no color (nil),
    # never a fabricated one. The category picker in the allocation dialog is
    # optional for every kind; the FK is per-family enforced by the model
    # (category.family_id must equal the allocation's family_id), same as the
    # existing account/recurring_transaction links.
    add_column :plan_allocations, :category_id, :uuid
    add_index :plan_allocations, :category_id
    add_foreign_key :plan_allocations, :categories, column: :category_id,
      on_delete: :nullify

    # 20261101130000_add_bank_logo_slug_to_accounts
    # favicon. The default resolution is a keyword match on the account name
    # (config/bank_logo_slugs.yml); this column lets the owner pin an explicit
    # logo per account from the bank config dialog's searchable picker.
    #
    # Nullable string: no slug = no logo (the diagram falls back to the keyword
    # match or nothing). The model validates the value against the vendored
    # logo set (app/services/bank_logo_slugs.rb); no runtime fetching anywhere.
    add_column :accounts, :bank_logo_slug, :string

    # 20261102100000_extend_plan_role_check_constraint
    # from savings_bucket / credit_card_payoff / loan_payoff to the owner's five
    # account kinds -- Savings / Checking / Credit Card / Loan / Investment.
    # plan_role is a plain nullable string (Account::PLAN_ROLES is the only
    # enum), so extending the set is a check-constraint change only: recreate
    # chk_accounts_plan_role with the five values. Reversible: down restores the
    # original three-value constraint.
    remove_check_constraint :accounts, name: "chk_accounts_plan_role"
    add_check_constraint :accounts,
      "plan_role IS NULL OR plan_role::text = ANY (ARRAY['savings_bucket'::text, 'checking'::text, 'credit_card_payoff'::text, 'loan_payoff'::text, 'investment'::text])",
      name: "chk_accounts_plan_role"
  end

  def down
    # rollback order: reverse of the original timestamps
    # The plan_role constraint added by the up step stays in place through
    # the rest of the rollback and is dropped with the plan_role column
    # below — restoring the old 3-value set here would reject rows that
    # already carry the new values.

    # 20261101130000_add_bank_logo_slug_to_accounts
    remove_column :accounts, :bank_logo_slug

    # 20261101110000_add_category_id_to_plan_allocations
    remove_foreign_key :plan_allocations, :categories, column: :category_id
    remove_index :plan_allocations, :category_id
    remove_column :plan_allocations, :category_id

    # 20261101100000_add_plan_sub_accounts
    remove_column :accounts, :auto_transfer_target_ids
    remove_index :accounts, :parent_account_id
    remove_column :accounts, :parent_account_id

    # 20261029100002_add_plan_max_account_links_to_recurring_transactions
    remove_check_constraint :recurring_transactions, name: "chk_recurring_transactions_plan_max_account_links"
    remove_column :recurring_transactions, :plan_max_account_links

    # 20261029100001_add_plan_role_and_auto_transfer_to_accounts
    remove_check_constraint :accounts, name: "chk_accounts_plan_role"
    remove_index :accounts, :auto_transfer_to_account_id
    remove_column :accounts, :auto_transfer_to_account_id
    remove_column :accounts, :plan_role

    # 20261029100000_create_plan_allocations
    drop_table :plan_allocations

    # 20261028000000_add_plan_owner_user_id_to_recurring_transactions
    remove_index :recurring_transactions, column: :plan_owner_user_id
    remove_column :recurring_transactions, :plan_owner_user_id

    # 20261026100002_create_family_plan_settings
    drop_table :family_plan_settings

    # 20261026100001_add_plan_fields_to_accounts
    remove_check_constraint :accounts, name: "chk_accounts_plan_owner_consistency"
    remove_check_constraint :accounts, name: "chk_accounts_plan_ownership"
    remove_index :accounts, column: :plan_owner_user_id
    remove_column :accounts, :plan_order
    remove_column :accounts, :plan_owner_user_id
    remove_column :accounts, :plan_ownership

    # 20261026100000_create_income_account_allocations
    drop_table :income_account_allocations
  end
end
