# frozen_string_literal: true

# A labelled "Expand all / Collapse all" toggle for a group of <details>
# elements. The visible label and aria-expanded state are driven by
# client-side JS (the inline scripts in the account sidebar and the dashboard
# balance sheet), so this component renders only the static shell: the
# <button>, the data attributes those scripts key off, the icon, and the
# initial label.
#
# Consolidates the hand-built <button> markup that previously appeared four
# times (three account-sidebar tabs + the dashboard balance sheet). The
# design-system guide requires proposing a shared DS::* primitive before the
# second copy of a hand-built shape lands.
#
# The two labels are localized at the call site and passed in, so the
# component stays locale-agnostic. The scripts read the labels back from
# data-expand-label / data-collapse-label, so this component sets those from
# the same values it renders as the visible label.
#
# `data:` carries the presence marker the scripts select on
# (e.g. `account_sidebar_expand_all:` / `balance_sheet_expand_all:`). It is
# passed as `true` so Rails renders a bare `data-...` attribute; a `nil`
# value would be dropped by the tag helper and break the selector.
class DS::ExpandToggle < DesignSystemComponent
  # Shared outline style (border-primary / bg-container / text-primary,
  # hover:bg-surface-inset). The sidebar call site appends `shrink-0` so the
  # button does not compress next to the flex-1 "New" link; the dashboard
  # button is the sole child of a justify-end row and needs no shrink guard.
  DEFAULT_CLASSES = "inline-flex items-center gap-1.5 rounded-lg border border-primary bg-container px-3 py-1.5 text-sm font-medium text-primary hover:bg-surface-inset transition-colors"

  attr_reader :expand_label, :collapse_label, :data, :extra_classes

  def initialize(expand_label:, collapse_label:, data:, class_name: nil)
    @expand_label = expand_label
    @collapse_label = collapse_label
    @data = data
    @extra_classes = class_name
  end

  def merged_opts
    {
      type: "button",
      class: class_names(DEFAULT_CLASSES, extra_classes),
      data: data.merge(expand_label: expand_label, collapse_label: collapse_label),
      aria: { expanded: false }
    }
  end
end
