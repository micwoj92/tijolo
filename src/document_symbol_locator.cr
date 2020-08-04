require "./fuzzy_locator"

class DocumentSymbolLocator < FuzzyLocator
  @symbols : Array(LSP::SymbolInformation)?

  PLACEHOLDER = "Waiting for language server..."

  def initialize
    super(PLACEHOLDER)
  end

  def shortcut : Char
    '.'
  end

  def description : String
    "Symbols in Current Document"
  end

  def selected(current_view : View?)
    super
    if current_view.nil?
      self.placeholder = "Open a file to use this locator"
      return
    elsif current_view.file_path.nil?
      self.placeholder = "Save this file first to use this locator"
      return
    end

    current_view.language.document_symbols(current_view.file_path.not_nil!) do |symbols|
      @symbols = symbols
      self.haystack = Fzy::PreparedHaystack.new(symbols.map(&.name))
    end
  rescue e : AppError
    self.placeholder = e.message || "Unknow error"
  end

  def unselected
    self.placeholder = PLACEHOLDER
    @symbols = nil
    self.haystack = nil
  end

  def activate(locator : Locator, match : Fzy::Match)
    symbols = @symbols
    return if symbols.nil?

    pos = symbols[match.index].location.range.start
    line = pos.line
    col = pos.character
    locator.notify_locator_goto_line_col(line, col)
  end
end
