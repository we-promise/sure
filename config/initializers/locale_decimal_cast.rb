# Form money fields submit locale decimals ("2,65"). Cast them before AR's
# decimal type sees the comma and truncates at 2.
module LocaleDecimalCast
  def cast(value)
    super(value.is_a?(String) ? LocaleNumber.parse(value) : value)
  end
end

Rails.application.config.to_prepare do
  unless ActiveRecord::Type::Decimal.ancestors.include?(LocaleDecimalCast)
    ActiveRecord::Type::Decimal.prepend(LocaleDecimalCast)
  end
end
