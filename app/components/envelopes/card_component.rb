class Envelopes::CardComponent < ApplicationComponent
  def initialize(envelope:)
    @envelope = envelope
  end

  attr_reader :envelope

  def progress_percent
    envelope.progress_percent
  end

  # Bar fill colour tracks status: red when overspent, green when funded /
  # reached, neutral while a sinking fund just ticks along.
  def bar_color
    case envelope.status
    when :negative then "var(--color-destructive)"
    when :reached, :on_track then "var(--color-success)"
    else "var(--budget-unused-fill)"
    end
  end

  def category_label
    envelope.category&.name || I18n.t("envelopes.envelope_card.no_category")
  end

  # Single screen-reader sentence for the whole-card link. Built from one
  # translation key so locales control ordering and punctuation rather than a
  # hard-coded join.
  def aria_label
    I18n.t("envelopes.envelope_card.aria_label",
           name: envelope.name,
           status: I18n.t("envelopes.status.#{envelope.status}"),
           balance: envelope.current_balance_money.format(precision: 0))
  end

  def contribution_line
    I18n.t("envelopes.envelope_card.contribution",
           amount: envelope.monthly_contribution_money.format(precision: 0))
  end

  def footer_line
    if envelope.negative?
      I18n.t("envelopes.envelope_card.overspent")
    elsif envelope.reached?
      I18n.t("envelopes.envelope_card.reached")
    elsif envelope.has_target? && envelope.months_to_target
      I18n.t("envelopes.envelope_card.months_to_target", count: envelope.months_to_target)
    else
      I18n.t("envelopes.envelope_card.sinking_fund")
    end
  end
end
