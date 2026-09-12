class Envelopes::StatusPillComponent < ApplicationComponent
  # Maps the envelope's status to the DS::Pill primitive's tone + glyph.
  # Outline style keeps the colored border on any card background.
  VARIANTS = {
    negative: { tone: :red,   icon: "triangle-alert" },
    reached:  { tone: :green, icon: "circle-check-big" },
    on_track: { tone: :green, icon: "circle-check" },
    tracking: { tone: :gray,  icon: "infinity" }
  }.freeze

  def initialize(envelope:)
    @envelope = envelope
  end

  def status_key
    @envelope.status
  end

  def variant
    VARIANTS.fetch(status_key, VARIANTS[:tracking])
  end

  def label
    I18n.t("envelopes.status.#{status_key}", default: status_key.to_s.titleize)
  end
end
