GICrystal.require("GtkSource", "5")
require "./code_buffer"
require "./code_language"
require "./code_commenter"
require "./init"

class CodeEditor < GtkSource::View
  include CodeCommenter

  @search_context : GtkSource::SearchContext
  @search_settings : GtkSource::SearchSettings
  @search_mark : Gtk::TextMark

  @[GObject::Property]
  property search_occurences : String = ""
  getter language : CodeLanguage

  def initialize(source : IO?, @language : CodeLanguage)
    super(css_name: "codeeditor",
      show_line_numbers: true,
      monospace: true,
      auto_indent: true,
      smart_backspace: true,
      background_pattern: :grid,
      smart_home_end: :before)
    @search_settings = GtkSource::SearchSettings.new(wrap_around: true)
    @search_context = GtkSource::SearchContext.new(source_buffer, @search_settings)
    @search_mark = source_buffer.insert
    @search_context.notify_signal["occurrences-count"].connect { update_label_occurrences }

    key = Gtk::EventControllerKey.new(propagation_phase: :target)
    key.key_pressed_signal.connect(->on_key_press(UInt32, UInt32, Gdk::ModifierType))
    add_controller(key)

    supress_source_view_key_bindings
    setup(source)
  end

  def reload(source : IO)
    setup(source)
  end

  private def on_key_press(keyval : UInt32, keycode : UInt32, state : Gdk::ModifierType) : Bool
    if keyval.in?(Gdk::KEY_bracketleft, Gdk::KEY_parenleft, Gdk::KEY_braceleft)
      return insert_char_around_selection(keyval)
    end
    false
  end

  def insert_char_around_selection(keyval : UInt32) : Bool
    gsv_buffer = source_buffer
    return false unless gsv_buffer.has_selection?

    start_chr, end_chr = case (keyval)
                         when Gdk::KEY_bracketleft then {"[", "]"}
                         when Gdk::KEY_parenleft   then {"(", ")"}
                         when Gdk::KEY_braceleft   then {"{", "}"}
                         else
                           return false
                         end

    start_iter, end_iter = gsv_buffer.selection_bounds
    end_offset = end_iter.offset
    gsv_buffer.user_action do
      gsv_buffer.insert(start_iter, start_chr)
      start_iter.offset = end_offset + 1
      gsv_buffer.insert(start_iter, end_chr)
      start_iter.backward_char
      gsv_buffer.move_mark_by_name("selection_bound", start_iter)
    end
    true
  end

  private def supress_source_view_key_bindings
    sc_controller = Gtk::ShortcutController.new(propagation_phase: :capture)
    action = Gtk::CallbackAction.new(->(w : Gtk::Widget, v : GLib::Variant?) { true })
    # Remore shortcuts that clash with Tijolo shortcuts
    # move-words, move-lines and move-viewport
    trigger = Gtk::ShortcutTrigger.parse_string("<Alt>Up|<Alt>Right|<Alt>Down|<Alt>Left|<Alt><Shift>Up|<Alt><Shift>Down")
    shortcut = Gtk::Shortcut.new(action: action, trigger: trigger)
    sc_controller.add_shortcut(shortcut)
    add_controller(sc_controller)
  end

  private def setup(source)
    gsv_buffer = source_buffer
    gsv_buffer.text = source.gets_to_end if source
    unless @language.none?
      gsv_buffer.language = GtkSource::LanguageManager.default.language(@language.id)
    end

    self.color_scheme = Adw::StyleManager.default.color_scheme

    iter = gsv_buffer.iter_at_offset(0)
    gsv_buffer.place_cursor(iter)
  end

  # For compatibility with non-gsv CodeEditor
  {% for attr in %w(tab_width right_margin_position) %}
  def {{ attr.id }}=(value : Int32)
    self.{{ attr.id }} = value.to_u32
  end
  {% end %}

  def buffer : CodeBuffer
    buffer = super
    CodeBuffer.new(GtkSource::Buffer.cast(buffer))
  end

  private def source_buffer : GtkSource::Buffer
    buffer.buffer
  end

  def cursor_changed_signal
    source_buffer.notify_signal["cursor-position"]
  end

  def cursor_line_col
    buffer = self.buffer
    return {0, 0} if buffer.nil?

    iter = source_buffer.iter_at_offset(buffer.cursor_position)
    {iter.line, iter.line_offset}
  end

  private def current_iter : Gtk::TextIter
    buffer = source_buffer
    pos = buffer.cursor_position
    buffer.iter_at_offset(pos)
  end

  def sort_lines
    buffer = source_buffer
    start_iter, end_iter = buffer.selection_bounds
    # TODO: Present a focused popup, so th euser can choose to
    # - just sort
    # - remove duplicates
    # - reverse sort
    # - case sensitiviness
    buffer.sort_lines(start_iter, end_iter, :none, 0)
  end

  def goto_line(line : Int32, col : Int32)
    buffer = source_buffer
    iter = buffer.iter_at_line_offset(line, col)
    buffer.place_cursor(iter)
    scroll_to_iter(iter, 0.1, true, 0.0, 0.5)
  end

  def move_lines_up
    move_lines_signal.emit(false)
  end

  def move_lines_down
    move_lines_signal.emit(true)
  end

  def move_viewport_line_up
    move_viewport_signal.emit(:steps, -1)
  end

  def move_viewport_line_down
    move_viewport_signal.emit(:steps, 1)
  end

  def move_viewport_page_up
    move_viewport_signal.emit(:pages, -1)
  end

  def move_viewport_page_down
    move_viewport_signal.emit(:pages, 1)
  end

  def search_replace_started
    Log.warn { "Not implemented yet" }
  end

  private def word_at_cursor : String
    buffer = source_buffer
    start_iter = buffer.iter_at_mark(buffer.insert)
    return "" unless start_iter.inside_word

    start_iter.backward_word_start unless start_iter.starts_word
    end_iter = current_iter
    end_iter.forward_word_end
    buffer.select_range(start_iter, end_iter)
    buffer.text(start_iter, end_iter, false)
  end

  def search_started : String
    buffer = source_buffer
    text = if buffer.has_selection?
             buffer.text(*buffer.selection_bounds, false)
           else
             word_at_cursor
           end
    search_changed(text)
    text
  end

  def search_changed(text : String) : Nil
    text = GtkSource.utils_unescape_search_text(text)
    @search_settings.search_text = text
    @search_mark = source_buffer.insert
  end

  def search_next : Nil
    buffer = source_buffer
    search_iter = buffer.iter_at_mark(@search_mark)
    search_iter.forward_char
    valid, start_iter, end_iter = @search_context.forward(search_iter)
    search_found(start_iter, end_iter) if valid
    update_label_occurrences_async
  end

  def search_previous : Nil
    buffer = source_buffer
    search_iter = buffer.iter_at_mark(@search_mark)
    valid, start_iter, end_iter = @search_context.backward(search_iter)
    search_found(start_iter, end_iter) if valid
    update_label_occurrences_async
  end

  private def search_found(start_iter, end_iter)
    buffer = source_buffer
    buffer.move_mark(@search_mark, end_iter)
    buffer.select_range(start_iter, end_iter)
    scroll_to_iter(end_iter, 0.2, false, 0.0, 0.5)
  end

  def search_stopped
    @search_context.highlight = false
  end

  def update_label_occurrences_async
    GLib.idle_add do
      update_label_occurrences
      false
    end
  end

  private def update_label_occurrences
    occurrences_count = @search_context.occurrences_count
    select_start, select_end = source_buffer.selection_bounds
    occurrence_pos = @search_context.occurrence_position(select_start, select_end)
    text = if occurrences_count == -1
             ""
           elsif occurrence_pos == -1
             "#{occurrences_count} occurrences"
           else
             "#{occurrence_pos} of #{occurrences_count}"
           end
    self.search_occurences = text
  end

  def color_scheme=(scheme : Adw::ColorScheme)
    gsv_buffer = source_buffer
    style_manager = GtkSource::StyleSchemeManager.default

    if scheme.force_dark?
      gsv_buffer.style_scheme = style_manager.scheme("monokai")
    else
      gsv_buffer.style_scheme = style_manager.scheme("Adwaita")
    end
  end
end
