class Assistant::Function::GetAccountTypes < Assistant::Function
  class << self
    def name = "get_account_types"

    def description
      "Lists every Sure account type and the valid subtype values accepted by create_account and update_account."
    end
  end

  def params_schema
    build_schema(required: [], properties: {})
  end

  def call(params = {})
    {
      account_types: Accountable::TYPES.map do |type|
        accountable_class = Accountable.from_type(type)
        subtypes = account_subtypes_for(accountable_class)

        { type: type, subtypes: subtypes }
      end
    }
  end
end
