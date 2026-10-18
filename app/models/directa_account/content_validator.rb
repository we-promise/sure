class DirectaAccount::ContentValidator
  def initialize(directa_account)
    @directa_account = directa_account
  end

  def validate!
    return if @directa_account.content_compatible_for_import?

    raise DirectaItem::PortfolioNormalizer::Error.new(:holding_conflict)
  end
end
