# Which categories the Activity Breakdown trend chart draws. Selection only:
# the report totals and tables stay unfiltered. Values are category ids plus
# the stable Uncategorized sentinel, so a renamed category keeps working.
class Reports::CategorySelection
  Option = Data.define(:category, :value, :checked)

  UNCATEGORIZED = Category::UNCATEGORIZED_FILTER_VALUE

  attr_reader :selected_values

  def initialize(family, values)
    @family = family
    @selected_values = normalize(values)
  end

  def active?
    selected_values.any?
  end

  # One line per selected group: a selected parent covers its children, so the
  # child is not drawn a second time. Order follows the submitted selection.
  def group_values
    @group_values ||= begin
      ids = selected_values.reject { |value| value == UNCATEGORIZED }
      selected_ids = ids.to_set
      roots = family.categories.where(id: ids).reject do |category|
        category.parent_id.present? && selected_ids.include?(category.parent_id.to_s)
      end

      values = roots.map { |category| category.id.to_s }
      values << UNCATEGORIZED if selected_values.include?(UNCATEGORIZED)
      values
    end
  end

  def selected_count
    group_values.size
  end

  def options
    @options ||= begin
      categories = [ Category.uncategorized, *family.categories.alphabetically_by_hierarchy ]
      categories.map do |category|
        value = value_for(category)
        Option.new(category: category, value: value, checked: checked?(category, value))
      end
    end
  end

  private
    attr_reader :family

    def normalize(values)
      raw = if values.is_a?(Array)
        values
      elsif values.is_a?(String)
        [ values ]
      else
        []
      end

      return [] if raw.empty?

      allowed = family.categories.pluck(:id).map(&:to_s)
      raw.reject(&:blank?).map(&:to_s).uniq.select do |value|
        value == UNCATEGORIZED || allowed.include?(value)
      end
    end

    def value_for(category)
      category.persisted? ? category.id.to_s : UNCATEGORIZED
    end

    # A parent selection cascades to its children, matching the checkbox
    # behaviour in category_filter_controller.js.
    def checked?(category, value)
      return true if selected_values.include?(value)

      category.parent_id.present? && selected_values.include?(category.parent_id.to_s)
    end
end
