# frozen_string_literal: true

# The merchant matcher and Bayes become rules, Merchant matcher and Category
# classifier, at the top of every family's order (users can move them). Each
# is on where the family already has an active rule doing the same with AI,
# so only families paying for that get the free step before it. Their old
# on/off settings go, and the account filter: a rule's conditions choose
# accounts now.
class AddClassifierRules < ActiveRecord::Migration[8.1]
  RULES = [
    # action_type, name, position, the AI action that turns it on
    [ "fill_similar_merchants", "Merchant matcher", 1, "auto_detect_merchants" ],
    [ "bayes_categorize", "Category classifier", 2, "auto_categorize" ]
  ].freeze

  def up
    execute "UPDATE rules SET position = position + #{RULES.size}"

    RULES.each do |action_type, name, position, ai_action_type|
      execute <<~SQL
        WITH added AS (
          INSERT INTO rules (family_id, name, resource_type, active, position, created_at, updated_at)
          SELECT families.id, #{connection.quote(name)}, 'transaction',
                 EXISTS (
                   SELECT 1 FROM rules ai_rules
                   JOIN rule_actions ON rule_actions.rule_id = ai_rules.id
                   WHERE ai_rules.family_id = families.id AND ai_rules.active
                     AND rule_actions.action_type = #{connection.quote(ai_action_type)}
                 ),
                 #{position}, NOW(), NOW()
          FROM families
          RETURNING id
        )
        INSERT INTO rule_actions (rule_id, action_type, created_at, updated_at)
        SELECT id, #{connection.quote(action_type)}, NOW(), NOW() FROM added
      SQL
    end

    execute "UPDATE families SET bayes_settings = bayes_settings - 'categorize_after_sync' - 'fill_similar_merchants' - 'excluded_account_ids'"
  end

  # Removes the two actions, and the rules left without one, then numbers
  # each family's rules 1… again in their order.
  def down
    action_types = RULES.map { |action_type, *| connection.quote(action_type) }.join(", ")
    execute "DELETE FROM rule_actions WHERE action_type IN (#{action_types})"
    emptied = "SELECT id FROM rules WHERE NOT EXISTS (SELECT 1 FROM rule_actions WHERE rule_actions.rule_id = rules.id)"
    execute "DELETE FROM rule_runs WHERE rule_id IN (#{emptied})"
    execute "DELETE FROM rule_conditions WHERE rule_id IN (#{emptied})"
    execute "DELETE FROM rules WHERE id IN (#{emptied})"
    execute <<~SQL
      UPDATE rules SET position = ranked.rn
      FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY family_id ORDER BY position, created_at, id) AS rn FROM rules) ranked
      WHERE rules.id = ranked.id
    SQL
  end
end
