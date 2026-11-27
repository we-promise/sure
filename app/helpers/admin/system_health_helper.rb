module Admin::SystemHealthHelper
  def configuration_health_text(text)
    safe_join(text.split(/\b([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b/).each_with_index.map do |part, index|
      index.odd? ? tag.code(part) : part
    end)
  end
end
