module TaxWorkbook
  ImportResult = Data.define(:success, :import, :errors) do
    def success?
      success
    end
  end
end
