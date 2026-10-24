# The rules page as a list of top-level items: rules without a group and rule
# groups, in any mix. A group holds its rules as one block, so the list still
# reads as the order the rules run in.
#
# Rules and groups share one position sequence. A group's position marks its
# place among the top-level items, and its rules follow it directly, so
# Rule.ordered (by position) is the same order the page shows. Every change
# that moves a rule into or out of a group places it to keep it that way.
class Rule::Layout
  Item = Data.define(:rule, :group, :rules) do
    def group? = group.present?

    def key = group? ? "group:#{group.id}" : "rule:#{rule.id}"
  end

  def initialize(family, rules: family.rules.ordered)
    @family = family
    @rules = rules
  end

  def items
    @items ||= begin
      rules_by_group = rules.to_a.group_by(&:rule_group_id)
      groups = family.rule_groups.order(:position, :created_at, :id).to_a

      group_items = groups.map { |group| [ group.position, 0, Item.new(rule: nil, group: group, rules: rules_by_group.fetch(group.id, [])) ] }
      rule_items = rules_by_group.fetch(nil, []).map { |rule| [ rule.position, 1, Item.new(rule: rule, group: nil, rules: []) ] }

      # A group sorts before a rule on the same position, so a rule that just
      # left a group stays below it.
      (group_items + rule_items).each_with_index.sort_by { |(position, kind, _), index| [ position, kind, index ] }.map { |(_, _, item), _| item }
    end
  end

  def groups
    items.select(&:group?).map(&:group)
  end

  # Moves a rule to right after the group's last other rule: the end of the
  # group it joined, or right below the group it left. Only the items after
  # that spot shift, so an import that groups many rules stays linear.
  def place_after_group!(rule, group)
    with_lock do
      anchor = [
        family.rule_groups.where(id: group.id).pick(:position).to_i,
        family.rules.where(rule_group_id: group.id).where.not(id: rule.id).maximum(:position).to_i
      ].max

      family.rules.where.not(id: rule.id).where("position > ?", anchor).update_all("position = position + 1")
      family.rule_groups.where("position > ?", anchor).update_all("position = position + 1")
      rule.update_column(:position, anchor + 1)
    end
  end

  # Sets the order of the top-level items. keys lists every group and every
  # rule without a group exactly once (Item#key), so a stale page cannot drop
  # an item or put a rule outside its group.
  def reorder!(keys)
    keys = Array(keys).map(&:to_s)

    with_lock do
      current = Rule::Layout.new(family).items
      unless keys.size == current.size && keys.sort == current.map(&:key).sort
        raise ArgumentError, "keys must list every top-level item exactly once"
      end

      by_key = current.index_by(&:key)
      write_positions!(keys.map { |key| by_key.fetch(key) })
    end
  end

  # Sets the order of the rules inside a group. rule_ids lists every rule of
  # the group exactly once. The group keeps its place in the list.
  def reorder_group!(group, rule_ids)
    rule_ids = Array(rule_ids).map(&:to_s)

    with_lock do
      group_rules = family.rules.where(rule_group_id: group.id).ordered.to_a
      unless rule_ids.size == group_rules.size && rule_ids.sort == group_rules.map(&:id).sort
        raise ArgumentError, "rule_ids must list every rule of the group exactly once"
      end

      update_rule_positions!(rule_ids.zip(group_rules.map(&:position)))
    end
  end

  private
    attr_reader :family, :rules

    def with_lock(&block)
      Rule.transaction do
        Rule.lock_positions!(family)
        block.call
      end
    end

    def write_positions!(items)
      rule_positions = []
      group_positions = []
      position = 0

      items.each do |item|
        if item.group?
          group_positions << [ item.group.id, position += 1 ]
          item.rules.each { |rule| rule_positions << [ rule.id, position += 1 ] }
        else
          rule_positions << [ item.rule.id, position += 1 ]
        end
      end

      update_rule_positions!(rule_positions)
      update_positions!(RuleGroup, group_positions)
    end

    def update_rule_positions!(pairs)
      update_positions!(Rule, pairs)
    end

    def update_positions!(model, pairs)
      return if pairs.empty?

      encoder = PG::TextEncoder::Array.new
      table = model.quoted_table_name
      sql = model.sanitize_sql_array([ <<~SQL.squish, encoder.encode(pairs.map(&:first)), encoder.encode(pairs.map(&:last)), family.id ])
        UPDATE #{table} SET position = new_positions.position
        FROM unnest(?::uuid[], ?::integer[]) AS new_positions(id, position)
        WHERE #{table}.id = new_positions.id AND #{table}.family_id = ?
      SQL
      model.with_connection { |connection| connection.update(sql, "#{model.name} Update Positions") }
    end
end
