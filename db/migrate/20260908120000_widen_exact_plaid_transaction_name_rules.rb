# Plaid transaction names now carry the bank's original description alongside the
# merchant name ("Target" becomes "Target - TARGET 00023 SAN MATEO CA"), so that
# variants of one merchant can be told apart.
#
# Rule::ConditionFilter::TransactionName is a text filter, which exposes `=` and
# `!=` in addition to `like`/`not_like`. Only the latter compile with substring
# wildcards. A rule saying `name = "Target"` therefore stops matching once the
# name grows, and — worse, because it fails silently in the other direction — a
# rule saying `name != "Target"` starts matching the Target transactions it was
# written to exclude.
#
# Those rules were written against names this app produced, so the intent behind
# `= "Target"` is "these Target transactions". `like` expresses that intent under
# the new names; `=` no longer expresses anything the user meant.
#
# Scoped to families with a Plaid connection, since no other family's names
# change. This does widen those conditions: a family that deliberately wanted an
# exact match now gets a substring one. That is the lesser harm — the alternative
# leaves rules that quietly stop firing, or quietly start.
class WidenExactPlaidTransactionNameRules < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE rule_conditions
      SET operator = CASE operator WHEN '=' THEN 'like' ELSE 'not_like' END,
          updated_at = NOW()
      WHERE condition_type = 'transaction_name'
        AND operator IN ('=', '!=')
        AND (
          -- Top-level conditions carry rule_id; sub-conditions carry parent_id
          -- and leave rule_id null, so both shapes have to be reached.
          rule_id IN (
            SELECT id FROM rules
            WHERE family_id IN (SELECT DISTINCT family_id FROM plaid_items)
          )
          OR parent_id IN (
            SELECT c.id FROM rule_conditions c
            WHERE c.rule_id IN (
              SELECT id FROM rules
              WHERE family_id IN (SELECT DISTINCT family_id FROM plaid_items)
            )
          )
        )
    SQL
  end

  # Narrowing these back to `=` would break them again against the names they
  # now have, and the original operator is not recorded anywhere.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
