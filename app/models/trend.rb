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

    # No baseline to divide by: report a signed infinity that matches the
    # direction of the move, rather than always-positive infinity.
    return signed_infinity if previous.zero?

    # Measure the change against the *magnitude* of the prior value so the sign
    # reflects the actual direction of change. Dividing by a signed baseline
    # would flip the sign whenever `previous` is negative (e.g. a net worth
    # moving from -100 to -50 is +50%, not -50%).
    change = (current - previous).to_f

    (change / previous.to_f.abs * 100).round(1)
  end

  def percent_formatted
    if percent.finite?
      "#{percent.round(1)}%"
    else
      percent.positive? ? "＋∞" : "-∞"
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
    # An infinite percentage carrying the sign of the move's direction, used
    # when there is no baseline (previous is zero) to compute against.
    def signed_infinity
      if direction.up?
        Float::INFINITY
      elsif direction.down?
        -Float::INFINITY
      else
        0.0
      end
    end

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
