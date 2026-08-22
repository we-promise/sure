class PillComponentPreview < ViewComponent::Preview
  # @param tone select ["violet", "indigo", "fuchsia", "amber", "green", "gray", "red", "success", "warning", "error", "info", "neutral"]
  # @param style select ["soft", "filled", "outline"]
  # @param size select ["sm", "md"]
  # @param label text
  # @param show_dot toggle
  # @param dot_only toggle
  # @param marker toggle
  # @param icon text
  def default(tone: "violet", style: "soft", size: "sm", label: "Preview", show_dot: true, dot_only: false, marker: true, icon: nil)
    render DS::Pill.new(
      label: label,
      tone: tone.to_sym,
      style: style.to_sym,
      size: size.to_sym,
      show_dot: show_dot,
      dot_only: dot_only,
      marker: marker,
      icon: icon.presence
    )
  end

  # @!group Stage markers (marker: true — original #1829 shape)
  def canary
    render DS::Pill.new(label: "Canary", tone: :fuchsia)
  end

  def beta
    render DS::Pill.new(label: "Beta", tone: :violet)
  end

  def new_marker
    render DS::Pill.new(label: "New", tone: :indigo)
  end

  def dot_only_collapsed_sidebar
    render DS::Pill.new(dot_only: true, tone: :violet)
  end
  # @!endgroup

  # @!group Status badges (marker: false, semantic tones)
  # Badge mode is dot-less by default — tone + label carry the signal. Opt the
  # dot back in with show_dot: true only where it's genuinely additive (live /
  # temporal status, or a single sparse pill). status_active below shows the
  # opt-in; status_pending / status_archived show the clean default.
  def status_active
    render DS::Pill.new(label: "Active", tone: :success, marker: false, show_dot: true)
  end

  def status_pending
    render DS::Pill.new(label: "Pending", tone: :warning, marker: false)
  end

  def status_failed
    render DS::Pill.new(label: "Failed", tone: :error, marker: false, icon: "circle-alert")
  end

  def status_archived
    render DS::Pill.new(label: "Archived", tone: :neutral, marker: false)
  end

  def status_info
    render DS::Pill.new(label: "Syncing", tone: :info, marker: false, icon: "loader")
  end
  # @!endgroup

  # @!group Sizes (md)
  def status_md
    render DS::Pill.new(label: "Past due", tone: :error, marker: false, size: :md)
  end
  # @!endgroup

  # The categories/_badge recipe: user-chosen hex via custom_color, icon at
  # "sm", and truncate so the label ellipsizes inside a tight min-w-0 column.
  # @display container_classes max-w-[140px]
  def category_badge_truncating
    render DS::Pill.new(
      label: "Subscriptions & Memberships",
      custom_color: "#7c3aed",
      icon: "credit-card",
      icon_size: "sm",
      marker: false,
      size: :md,
      truncate: true
    )
  end
end
