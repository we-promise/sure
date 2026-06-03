# A single-arc circular progress ring, decoupled from any domain model.
#
# Extracted from the goal card's inline <svg> (issue #1899) so goals, loans,
# sub-account funding, etc. stop each hand-rolling the same two-circle SVG with
# slightly different chrome / colors / a11y. Pass a percent and a tone; the
# component owns the geometry (radius, circumference, dash offset) and the
# accessible progressbar markup.
#
# Not a segmented donut — that's the `donut-chart` Stimulus controller's job
# (budget/dashboard breakdowns, and the goals/show ring). This is the simple
# "X% of one thing" ring.
class DS::ProgressRing < DesignSystemComponent
  TONES = {
    success: "var(--color-success)",
    warning: "var(--color-warning)",
    destructive: "var(--color-destructive)",
    neutral: "var(--color-gray-400)"
  }.freeze

  # Track (unfilled remainder) color. Reuses the existing token to keep the
  # goal card pixel-identical. TODO(#1899 follow-up): rename this to a generic
  # --color-progress-track-fill in the token source — that change also touches
  # the budget donut surfaces, so it's deferred out of this extraction.
  DEFAULT_TRACK = "var(--budget-unused-fill)".freeze

  attr_reader :size, :stroke_width, :label, :show_percent

  def initialize(percent:, size: 64, stroke_width: 6, tone: :neutral, label: nil, show_percent: true, track: DEFAULT_TRACK)
    @percent = percent
    @size = size
    @stroke_width = stroke_width
    @tone = tone.to_sym
    @label = label
    @show_percent = show_percent
    @track = track
  end

  def clamped_percent
    [ [ @percent.to_i, 0 ].max, 100 ].min
  end

  def stroke_color
    TONES.fetch(@tone, TONES[:neutral])
  end

  def track_color
    @track
  end

  def center
    size / 2.0
  end

  def radius
    (size - stroke_width) / 2.0
  end

  def circumference
    2 * Math::PI * radius
  end

  # Length of the dash gap that hides the unfilled portion of the arc.
  def dash_offset
    circumference * (1 - clamped_percent / 100.0)
  end

  # Center label scales with the ring so 64px reads ~11px (the goal card's size)
  # and a 180px ring reads ~30px without a per-callsite font class.
  def percent_font_px
    (size * 0.17).round
  end

  # role=progressbar + value/label only when a label is supplied; otherwise the
  # ring is decorative (aria-hidden via the inner svg) and the caller labels it.
  def wrapper_aria
    return {} if label.blank?

    { role: "progressbar", aria: { valuenow: clamped_percent, valuemin: 0, valuemax: 100, label: label } }
  end
end
