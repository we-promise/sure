class Trend
  include ActiveModel::Validations

  DIRECTIONS = %w[up down].freeze

  attr_reader :current, :previous, :favorable_direction

  validates :current, presence: true

  def initialize(current:, previous:, favorable_direction: nil)
    @current = current
    @previous = previous || 0
    @favorable_direction = (favorable_direction.presence_in(DIRECTIONS) || "up").inquiry

    validate!
  end

  def direction
    if current == previous
      "flat"
    elsif current > previous
      "up"
    else
      "down"
    end.inquiry
  end

  def color
    case direction
    when "up"
      favorable_direction.down? ? red_hex : green_hex
    when "down"
      favorable_direction.down? ? green_hex : red_hex
    else
      gray_hex
    end
  end

  def icon
    if direction.flat?
      "minus"
    elsif direction.up?
      "arrow-up"
    else
      "arrow-down"
    end
  end

  def value
    current - previous
  end

  def percent
    return 0.0 if previous.zero? && current.zero?
    return (direction.up? ? Float::INFINITY : -Float::INFINITY) if previous.zero?

    change = (current - previous).to_f

    # Divide by the absolute baseline so the sign of the percentage always
    # matches the direction of the change, even when the baseline is negative
    # (e.g. net worth improving from -$2,000 to -$1,000 is +50%, not -50%)
    (change / previous.to_f.abs * 100).round(1)
  end

  def percent_formatted
    if percent.finite?
      "#{percent.round(1)}%"
    else
      percent > 0 ? "＋∞" : "-∞"
    end
  end

  def as_json
    {
      value: value,
      percent: percent,
      percent_formatted: percent_formatted,
      current: current,
      previous: previous,
      color: color,
      icon: icon
    }
  end

  private
    def red_hex
      "var(--color-destructive)"
    end

    def green_hex
      "var(--color-success)"
    end

    def gray_hex
      "var(--color-gray)"
    end
end
