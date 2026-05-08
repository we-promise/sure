class Settings::GuidesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Guides", nil ]
    ]
    renderer = Redcarpet::Render::HTML.new(
      filter_html: true,
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
