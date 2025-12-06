class RuleImport < Import
  def import!
    transaction do
      rows.each do |row|
        create_or_update_rule_from_row(row)
      end
    end
  end

  def column_keys
    %i[name resource_type active effective_date conditions actions]
  end

  def required_column_keys
    %i[resource_type conditions actions]
  end

  def mapping_steps
    []
  end

  def dry_run
    { rules: rows.count }
  end

  def csv_template
    template = <<-CSV
      name,resource_type*,active,effective_date,conditions*,actions*
      "Categorize groceries","transaction",true,2024-01-01,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"grocery\"}]","[{\"action_type\":\"set_transaction_category\",\"value\":\"Groceries\"}]"
      "Auto-categorize transactions","transaction",true,,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"amazon\"}]","[{\"action_type\":\"auto_categorize\"}]"
    CSV

    CSV.parse(template, headers: true)
  end

  def generate_rows_from_csv
    rows.destroy_all

    csv_rows.each do |row|
      rows.create!(
        name: row["name"].to_s.strip,
        resource_type: row["resource_type"].to_s.strip,
        active: parse_boolean(row["active"]),
        effective_date: row["effective_date"].to_s.strip,
        conditions: row["conditions"].to_s.strip,
        actions: row["actions"].to_s.strip,
        currency: default_currency
      )
    end
  end

  private

    def create_or_update_rule_from_row(row)
      rule_name = row.name.to_s.strip.presence
      resource_type = row.resource_type.to_s.strip

      # Validate resource type
      unless resource_type == "transaction"
        errors.add(:base, "Unsupported resource type: #{resource_type}")
        raise ActiveRecord::RecordInvalid.new(self)
      end

      # Parse conditions and actions from JSON
      begin
        conditions_data = JSON.parse(row.conditions)
        actions_data = JSON.parse(row.actions)
      rescue JSON::ParserError => e
        errors.add(:base, "Invalid JSON in conditions or actions: #{e.message}")
        raise ActiveRecord::RecordInvalid.new(self)
      end

      # Validate we have at least one action
      if actions_data.empty?
        errors.add(:base, "Rule must have at least one action")
        raise ActiveRecord::RecordInvalid.new(self)
      end

      # Find or create rule
      rule = if rule_name.present?
        family.rules.find_or_initialize_by(name: rule_name, resource_type: resource_type)
      else
        family.rules.build(resource_type: resource_type)
      end

      rule.active = row.active || false
      rule.effective_date = parse_date(row.effective_date)

      # Clear existing conditions and actions
      rule.conditions.destroy_all
      rule.actions.destroy_all

      # Create conditions
      conditions_data.each do |condition_data|
        build_condition(rule, condition_data)
      end

      # Create actions
      actions_data.each do |action_data|
        build_action(rule, action_data)
      end

      rule.save!
    end

    def build_condition(rule, condition_data, parent: nil)
      condition_type = condition_data["condition_type"]
      operator = condition_data["operator"]
      value = resolve_import_condition_value(condition_data)

      condition = if parent
        parent.sub_conditions.build(
          condition_type: condition_type,
          operator: operator,
          value: value
        )
      else
        rule.conditions.build(
          condition_type: condition_type,
          operator: operator,
          value: value
        )
      end

      # Handle compound conditions with sub_conditions
      if condition_data["sub_conditions"].present?
        condition_data["sub_conditions"].each do |sub_condition_data|
          build_condition(rule, sub_condition_data, parent: condition)
        end
      end

      condition
    end

    def build_action(rule, action_data)
      action_type = action_data["action_type"]
      value = resolve_import_action_value(action_data)

      rule.actions.build(
        action_type: action_type,
        value: value
      )
    end

    def resolve_import_condition_value(condition_data)
      condition_type = condition_data["condition_type"]
      value = condition_data["value"]

      return value unless value.present?

      # Map category names to UUIDs
      if condition_type == "transaction_category"
        category = family.categories.find_by(name: value)
        unless category
          category = family.categories.create!(
            name: value,
            color: Category::UNCATEGORIZED_COLOR,
            classification: "expense"
          )
        end
        return category.id
      end

      # Map merchant names to UUIDs
      if condition_type == "transaction_merchant"
        merchant = family.merchants.find_by(name: value)
        unless merchant
          merchant = family.merchants.create!(name: value)
        end
        return merchant.id
      end

      value
    end

    def resolve_import_action_value(action_data)
      action_type = action_data["action_type"]
      value = action_data["value"]

      return value unless value.present?

      # Map category names to UUIDs
      if action_type == "set_transaction_category"
        category = family.categories.find_by(name: value)
        # Create category if it doesn't exist
        unless category
          category = family.categories.create!(
            name: value,
            color: Category::UNCATEGORIZED_COLOR,
            classification: "expense",
            lucide_icon: "shapes"
          )
        end
        return category.id
      end

      # Map merchant names to UUIDs
      if action_type == "set_transaction_merchant"
        merchant = family.merchants.find_by(name: value)
        # Create merchant if it doesn't exist
        unless merchant
          merchant = family.merchants.create!(name: value)
        end
        return merchant.id
      end

      value
    end

    def parse_boolean(value)
      return true if value.to_s.downcase.in?(%w[true 1 yes y])
      return false if value.to_s.downcase.in?(%w[false 0 no n])
      false
    end

    def parse_date(value)
      return nil if value.blank?
      Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end
end
