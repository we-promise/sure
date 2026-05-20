# frozen_string_literal: true

# An extension to `button_to` helper.  All options are passed through to the `button_to` helper with some additional
# options available.
class DS::Button < DS::Buttonish
  attr_reader :confirm

  def initialize(confirm: nil, **opts)
    super(**opts)
    @confirm = confirm
  end

  def container(&block)
    if href.present?
      button_to(href, **merged_opts, &block)
    else
      content_tag(:button, **merged_opts, &block)
    end
  end

  private
    def merged_opts
      merged_opts = opts.dup || {}
      extra_classes = merged_opts.delete(:class)
      data = merged_opts.delete(:data) || {}

      if confirm.present?
        data = data.merge(turbo_confirm: confirm.to_data_attribute)
      end

      if frame.present?
        data = data.merge(turbo_frame: frame)
      end

      # `content_tag(:button, ...)` defaults to `type="submit"` per the HTML
      # spec — meaning a DS::Button rendered inside a form will steal Enter-key
      # submission from the first text input. Default to `type="button"` so
      # callers must opt into submit behavior explicitly. `button_to` (href
      # branch) wraps the button in its own form, so submit there is correct
      # and we leave its default alone.
      if href.blank?
        merged_opts[:type] ||= "button"
      end

      # Icon-only buttons have no visible text node, so screen readers fall
      # back to announcing "button" with no name. Derive a humanized fallback
      # from the icon key so AT users hear *something* meaningful; explicit
      # `aria: { label: }` on the caller still wins.
      if icon_only? && icon.present?
        aria = (merged_opts[:aria] || {}).symbolize_keys
        if aria[:label].blank? && merged_opts[:"aria-label"].blank?
          aria[:label] = icon.to_s.tr("-_", " ").capitalize
          merged_opts[:aria] = aria
        end
      end

      merged_opts.merge(
        class: class_names(container_classes, extra_classes),
        data: data
      )
    end
end
