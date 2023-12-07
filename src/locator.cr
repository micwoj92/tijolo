require "fzy"

require "./locator_item"
require "./locator_provider"
require "./file_locator"
require "./line_locator"

@[Gtk::UiTemplate(file: "#{__DIR__}/ui/locator.ui", children: %w(entry results_view))]
class Locator < Gtk::Popover
  include Gtk::WidgetTemplate
  include Gio::ListModel

  @locator_providers = Hash(Char, LocatorProvider).new
  @default_locator_provider : LocatorProvider
  @current_locator_provider : LocatorProvider

  @entry : Gtk::SearchEntry
  @results_view : Gtk::ListView
  @selection_model : Gtk::SingleSelection

  @result_items = [] of LocatorItem
  @result_size = 0

  def initialize(project)
    super(has_arrow: false, position: :top)

    @results_view = Gtk::ListView.cast(template_child("results_view"))
    @results_view.model = @selection_model = Gtk::SingleSelection.new
    @entry = Gtk::SearchEntry.cast(template_child("entry"))
    @entry.activate_signal.connect(&->entry_activated)
    @entry.search_changed_signal.connect(&->search_changed)

    @default_locator_provider = FileLocator.new(project)
    @current_locator_provider = LineLocator.new

    key_ctl = Gtk::EventControllerKey.new
    key_ctl.key_pressed_signal.connect(&->entry_key_pressed(UInt32, UInt32, Gdk::ModifierType))
    @entry.add_controller(key_ctl)

    @selection_model.model = self
    @results_view.activate_signal.connect(->row_activated(UInt32))

    init_locators
  end

  def init_locators
    [LineLocator.new].each do |locator|
      @locator_providers[locator.shortcut] = locator
    end
  end

  def text=(text : String)
    @entry.text = text
    @entry.position = text.size
  end

  def show(*, select_text : Bool, view : View?)
    @entry.grab_focus
    @entry.select_region(0, -1) if select_text
    popup
  end

  def hide
    popdown
  end

  private def entry_key_pressed(key_val : UInt32, _key_code : UInt32, _modifier : Gdk::ModifierType)
    if key_val == Gdk::KEY_Escape
      hide
      activate_action("win.focus_editor", nil)
      return false
    end

    if key_val == Gdk::KEY_Up
      selected = @selection_model.selected
      return false if selected.zero?

      @selection_model.selected = selected - 1
      return true
    elsif key_val == Gdk::KEY_Down
      return true if @result_size < 2 # First item is already selected...

      selected = @selection_model.selected + 1
      @selection_model.selected = selected if selected < @result_size
      return true
    end
    false
  end

  private def search_changed
    text = @entry.text

    # Due to https://gitlab.gnome.org/GNOME/gtk/-/issues/5340
    # GTK emit search_changed signal for no reasons at begining, so we need this check here.
    return if text.empty?

    @current_locator_provider = find_locator(text)

    text = text[2..-1] if @current_locator_provider != @default_locator_provider
    old_size = @result_size
    @result_size = @current_locator_provider.search_changed(text)
    items_changed(0, old_size, @result_size)
    @selection_model.selected = 0
  end

  private def find_locator(text)
    return @default_locator_provider if text.size < 2 || !text[1].whitespace?

    @locator_providers[text[0]]? || @default_locator_provider
  end

  private def entry_activated
    row_activated(@selection_model.selected)
  end

  private def row_activated(index : UInt32)
    hide if @current_locator_provider.activate(self, index)
  end

  @[GObject::Virtual]
  def get_n_items : UInt32
    @result_size.to_u32
  end

  @[GObject::Virtual]
  def get_item(pos : UInt32) : GObject::Object?
    return if pos >= @result_size

    while @result_items.size <= pos
      @result_items << LocatorItem.new
    end

    item = @result_items[pos]
    @current_locator_provider.bind(item, pos.to_i32)
    item
  end

  @[GObject::Virtual]
  def get_item_type : UInt64
    LocatorItem.g_type
  end
end
