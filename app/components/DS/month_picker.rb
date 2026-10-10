class DS::MonthPicker < DesignSystemComponent
  attr_reader :name, :label, :value, :year, :month, :data

  def initialize(name:, label:, value:, data: {})
    @name, @label, @value, @data = name, label, value, data
    if value.is_a?(String) && (match = value.match(/\A(\d{4})-(\d{1,2})\z/))
      @year = match[1].to_i if match[1].to_i.positive?
      @month = match[2].to_i if (1..12).cover?(match[2].to_i)
    end
  end

  def years
    ((Date.current.year - 30..Date.current.year).to_a + [ year ]).compact.uniq.sort.reverse
  end

  def invalid_value?
    year.nil? || month.nil?
  end

  def select_classes
    "w-full min-w-0 bg-container text-primary rounded-lg border border-secondary min-h-11 text-base focus-ring px-2"
  end
end
