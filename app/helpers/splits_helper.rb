module SplitsHelper
  # Minimal stand-in for a Rails FormBuilder, providing just enough (an
  # `object_name` for field naming and a `label` helper) for DS::TagSelect to
  # render inside a dynamically-indexed split row that has no real bound
  # model/form builder of its own.
  class SplitFieldProxy
    attr_reader :object_name

    def initialize(template, object_name)
      @template = template
      @object_name = object_name
    end

    def label(method, text = nil, options = {}, &block)
      @template.label(object_name, method, text, options, &block)
    end
  end

  def split_field_proxy(index)
    SplitFieldProxy.new(self, "split[splits][#{index}]")
  end
end
