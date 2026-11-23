# Runs +change+ once a tool has accepted a preview_token and before it acts on
# it, as a writer committing in that window would.
module PreviewTokenTestHelper
  def change_after_token_check(function, &change)
    function.singleton_class.prepend(Module.new do
      define_method(:read_preview_token) do |*args|
        super(*args).tap { |payload| change.call if payload }
      end
    end)
  end
end
