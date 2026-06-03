class ProgressRingComponentPreview < ViewComponent::Preview
  # @param percent number
  # @param size number
  # @param stroke_width number
  # @param tone select ["success", "warning", "destructive", "neutral"]
  # @param show_percent toggle
  # @param label text
  def default(percent: 65, size: 64, stroke_width: 6, tone: "neutral", show_percent: true, label: nil)
    render DS::ProgressRing.new(
      percent: percent,
      size: size,
      stroke_width: stroke_width,
      tone: tone.to_sym,
      show_percent: show_percent,
      label: label.presence
    )
  end

  # @!group Tones (50%)
  def success
    render DS::ProgressRing.new(percent: 50, tone: :success)
  end

  def warning
    render DS::ProgressRing.new(percent: 50, tone: :warning)
  end

  def destructive
    render DS::ProgressRing.new(percent: 50, tone: :destructive)
  end

  def neutral
    render DS::ProgressRing.new(percent: 50, tone: :neutral)
  end
  # @!endgroup

  # @!group Sizes
  def small_48
    render DS::ProgressRing.new(percent: 72, size: 48, stroke_width: 5, tone: :success)
  end

  def medium_64
    render DS::ProgressRing.new(percent: 72, size: 64, stroke_width: 6, tone: :success)
  end

  def large_180
    render DS::ProgressRing.new(percent: 72, size: 180, stroke_width: 10, tone: :success)
  end
  # @!endgroup

  # @!group Edges
  def empty_0
    render DS::ProgressRing.new(percent: 0, tone: :neutral)
  end

  def full_100
    render DS::ProgressRing.new(percent: 100, tone: :success)
  end

  def clamps_over_100
    render DS::ProgressRing.new(percent: 140, tone: :success)
  end

  def without_center_percent
    render DS::ProgressRing.new(percent: 40, tone: :warning, show_percent: false)
  end
  # @!endgroup
end
