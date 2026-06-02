class Settings::GuidesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.guides"), nil ]
    ]
    # filter_html intentionally OFF: the source markdown
    # (docs/onboarding/guide.md) is shipped with the app, not user-controlled,
    # and relies on raw <img> / <br/> tags for layout. The XSS protection
    # filter_html provides only matters for user-supplied content — see the
    # `markdown` helper in application_helper.rb for that case.
    renderer = Redcarpet::Render::HTML.new(
      link_attributes: { target: "_blank", rel: "noopener noreferrer" }
    )
    markdown = Redcarpet::Markdown.new(renderer,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      superscript: true
    )
    @guide_content = markdown.render(File.read(Rails.root.join("docs/onboarding/guide.md")))
  end
end
