# An extension to `link_to` helper.  All options are passed through to the `link_to` helper with some additional
# options available.
class DS::Link < DS::Buttonish
  attr_reader :frame

  VARIANTS = VARIANTS.reverse_merge(
    default: {
      # Underline + `text-link` so the link is distinguishable by more
      # than color alone (WCAG 1.4.1). Keyboard focus uses the canonical
      # `.focus-ring` (#2136) so every primitive shares one indicator.
      container_classes: "text-link underline underline-offset-2 hover:no-underline focus-ring",
      icon_classes: "text-secondary"
    }
  ).freeze

  def merged_opts
    merged_opts = opts.dup || {}
    data = merged_opts.delete(:data) || {}

    if frame
      data = data.merge(turbo_frame: frame)
    end

    # External link hardening: `target="_blank"` without `rel="noopener"`
    # exposes window.opener to the new tab (reverse-tabnabbing). Always
    # set `noopener noreferrer` when we send the user off-tab. Authors
    # can override by passing `rel:` explicitly.
    if merged_opts[:target].to_s == "_blank"
      merged_opts[:rel] ||= "noopener noreferrer"
    end

    # Icon-only links have no visible text node, so screen readers fall
    # back to announcing the href. Derive a humanized fallback from the
    # icon key so AT users hear *something* meaningful; explicit
    # `aria: { label: }` on the caller still wins. Mirrors DS::Button.
    #
    # When the link also opens in a new tab, fold the cue into the
    # generated `aria-label` itself — `aria-label` overrides the
    # descendant accessible name, so the sr-only "(opens in new tab)"
    # span in the template would otherwise be masked.
    if icon_only? && icon.present?
      aria = (merged_opts[:aria] || {}).symbolize_keys
      if aria[:label].blank? && merged_opts[:"aria-label"].blank?
        label = icon.to_s.tr("-_", " ").humanize
        if merged_opts[:target].to_s == "_blank"
          label = "#{label} #{I18n.t("ds.link.opens_in_new_tab", default: "(opens in new tab)")}"
        end
        aria[:label] = label
        merged_opts[:aria] = aria
      end
    end

    merged_opts.merge(
      class: class_names(container_classes, extra_classes),
      data: data
    )
  end

  # Render an sr-only suffix when the link opens in a new tab so AT
  # users hear "(opens in new tab)" — visual is a separate concern
  # (callers can render a `external-link` icon if they want a glyph).
  def opens_in_new_tab?
    opts[:target].to_s == "_blank"
  end

  private
    def container_size_classes
      super unless variant == :default
    end
end
