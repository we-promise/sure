# The blur Privacy Mode applies to amounts inside SVG charts (see
# privacy-mode.css). WebKit does not reliably apply a CSS blur() to SVG
# elements, while an SVG filter referenced from CSS works in every engine, so
# the layout renders this definition once and the stylesheet points SVG text
# at it. It is sized to nothing rather than display:none, which would make the
# reference invalid.
class DS::PrivacyBlurFilter < DesignSystemComponent
  ID = "privacy-mode-blur".freeze
end
