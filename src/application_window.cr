require "./project"
require "./project_monitor"
require "./welcome_widget"
require "./view_manager"
require "./view_factory"
require "./terminal_view"
require "./git_branch_model"
require "./locator"
require "./theme_selector"
require "./save_modified_views_dialog"
require "./sidebar"

@[Gtk::UiTemplate(file: "#{__DIR__}/ui/application_window.ui", children: %w(header title sidebar primary_menu git_branches_menu git_branch_label git_branch_btn))]
class ApplicationWindow < Adw::ApplicationWindow
  include Gtk::WidgetTemplate

  getter project : Project
  @project_monitor : ProjectMonitor
  @git_model : GitBranchModel
  @sidebar : Adw::OverlaySplitView
  @view_manager : ViewManager?
  private getter locator : Locator

  def initialize(application : Application, @project : Project)
    super(title: "No Project")

    @git_model = GitBranchModel.new
    @project_monitor = ProjectMonitor.new(@project)
    @sidebar = Adw::OverlaySplitView.cast(template_child("sidebar"))
    @locator = Locator.new(@project)

    self.application = application

    primary_menu = Gtk::MenuButton.cast(template_child("primary_menu"))
    popover_primary_menu = Gtk::PopoverMenu.cast(primary_menu.popover.not_nil!)
    popover_primary_menu.add_child(ThemeSelector.new, "theme")

    key_ctl = Gtk::EventControllerKey.new(propagation_phase: :capture)
    key_ctl.key_pressed_signal.connect(->key_pressed(UInt32, UInt32, Gdk::ModifierType))
    key_ctl.key_released_signal.connect(->key_released(UInt32, UInt32, Gdk::ModifierType))
    add_controller(key_ctl)

    notify_signal["is-active"].connect(->on_window_active_changed(GObject::ParamSpec))

    if @project.valid?
      open_project
    else
      welcome
    end

    bind_settings(application.settings)
    setup_actions(application.settings)

    {% unless flag?(:release) %}
      add_css_class("devel")
    {% end %}
  end

  private def bind_settings(settings : Gio::Settings)
    settings.bind("window-width", self, "default-width", :default)
    settings.bind("window-height", self, "default-height", :default)
    settings.bind("window-maximized", self, "maximized", :default)
  end

  def application : Application
    super.not_nil!.as(Application)
  end

  def open_project(project_path : Path)
    raise ArgumentError.new if @project.valid?

    @project.root = project_path
    open_project
    open(project_path) if File.file?(project_path)
  rescue e : ProjectError
    Log.error { "Error loading project from #{project_path}: #{e.message}" }
  end

  private def open_project(project_path : GLib::Variant?)
    return if project_path.nil?

    open_project(Path.new(project_path.as_s))
  end

  private def open_project
    raise ArgumentError.new unless @view_manager.nil?

    title = Adw::WindowTitle.cast(template_child("title"))
    title.title = @project.name
    title.subtitle = @project.root.relative_to(Path.home).to_s

    @sidebar.pin_sidebar = false
    @sidebar.show_sidebar = true
    @sidebar.content.as?(WelcomeWidget).try(&.disconnect_all_signals)
    @sidebar.content = @view_manager = view_manager = ViewManager.new
    @locator.parent = title
    @locator.set_offset(0, 100)
    @sidebar.sidebar = sidebar = Sidebar.new(@project.root.to_s)

    @project.scan_files(on_finish: ->project_load_finished)

    # FIXME: Replace this once User objects work in signals.
    view_manager.on_view_changed do |view|
      sidebar.view_changed(view)
    end
    notify_signal["focus-widget"].connect { view_manager.focus_changed }
  end

  private def view_manager
    view_manager = @view_manager
    return view_manager unless view_manager.nil?

    open_project
    @view_manager.not_nil!
  end

  @[GObject::Virtual]
  def close_request : Bool
    views = @view_manager.try(&.modified_views)
    if views.nil? || views.empty?
      @locator.unparent # locator is child of Adw::WindowTitle 😅️, so we need to unparent before quit to avoid a warning
      return false
    end

    dlg = SaveModifiedViewsDialog.new(self, views)
    dlg.present do
      destroy
    end
    true
  end

  def project_load_finished
    @project_monitor.project_load_finished
    setup_git_menu if @git_model.start_monitoring(@project.root)
    enable_project_related_actions(true)
    @locator.project_load_finished(@project)
    self.title = @project.name
  end

  private def setup_git_menu
    change_action_state("change_git_branch", @git_model.current_branch)
    git_branches_menu = Gio::Menu.cast(template_child("git_branches_menu"))
    @git_model.menu_model = git_branches_menu

    git_branch_label = Gtk::Label.cast(template_child("git_branch_label"))
    @git_model.bind_property("current_branch", git_branch_label, "label", :none)
    git_branch_label.label = @git_model.current_branch

    Gtk::Widget.cast(template_child("git_branch_btn")).visible = true
  end

  private def welcome
    flap = Adw::OverlaySplitView.cast(template_child("sidebar"))
    welcome = WelcomeWidget.new
    flap.content = welcome
    self.focus_widget = welcome.entry
  end

  private def setup_actions(settings : Gio::Settings)
    app = application.not_nil!
    config = Config.instance
    actions = {show_locator:            ->show_locator,
               close_view:              ->close_current_view,
               close_all_views:         ->close_all_views,
               new_file:                ->new_file,
               new_terminal:            ->new_terminal,
               open:                    ->show_open_file_dialog,
               save:                    ->save_current_view,
               save_as:                 ->save_current_view_as,
               reload:                  ->reload_current_view,
               maximize_view:           ->maximize_view,
               show_hide_sidebar:       ->{ @sidebar.show_sidebar = !@sidebar.show_sidebar? },
               copy_from_terminal:      ->copy_to_clipboard,
               paste_in_terminal:       ->paste_from_clipboard,
               sort_lines:              ->sort_lines,
               comment_code:            ->comment_code,
               move_lines_up:           ->move_lines_up,
               move_lines_down:         ->move_lines_down,
               move_viewport_line_up:   ->move_viewport_line_up,
               move_viewport_line_down: ->move_viewport_line_down,
               move_viewport_page_up:   ->move_viewport_page_up,
               move_viewport_page_down: ->move_viewport_page_down,
               fullscreen:              ->toggle_fullscreen,
               find:                    ->find,
               find_next:               ->find_next,
               find_prev:               ->find_prev,
               goto_definition:         ->goto_definition,
    }
    actions.each do |name, closure|
      action = Gio::SimpleAction.new(name.to_s, nil)
      action.activate_signal.connect { closure.call }
      add_action(action)

      shortcut = config.shortcuts[name.to_s]
      app.set_accels_for_action("win.#{name}", {shortcut})
    end

    enable_project_related_actions(false)

    action = Gio::SimpleAction.new("focus_editor", nil)
    action.activate_signal.connect { with_current_view(&.grab_focus) }
    add_action(action)

    action = Gio::SimpleAction.new("open_file", GLib::VariantType.new("s"))
    action.activate_signal.connect(->open(GLib::Variant))
    add_action(action)

    action = Gio::SimpleAction.new("open_project", GLib::VariantType.new("s"))
    action.activate_signal.connect(->open_project(GLib::Variant))
    add_action(action)

    action = Gio::SimpleAction.new("show_goto", nil)
    action.activate_signal.connect { show_goto_line_locator }
    add_action(action)
    app.set_accels_for_action("win.show_goto", {config.shortcuts["goto_line"]})

    action = Gio::SimpleAction.new("goto_line", GLib::VariantType.new("s"))
    action.activate_signal.connect(->goto_line(GLib::Variant))
    add_action(action)

    action = Gio::SimpleAction.new_stateful("change_git_branch", GLib::VariantType.new("s"), "HEAD")
    action.activate_signal.connect(->change_git_branch(GLib::Variant))
    add_action(action)

    group = Gio::SimpleActionGroup.new
    action = settings.create_action("style-variant")
    group.add_action(action)

    insert_action_group("settings", group)
  end

  private def enable_project_related_actions(value : Bool)
    Gio::SimpleAction.cast(lookup_action("show_hide_sidebar").not_nil!).enabled = value
  end

  def key_pressed(key_val : UInt32, key_code : UInt32, modifier : Gdk::ModifierType) : Bool
    if modifier.control_mask? && key_val.in?({Gdk::KEY_Tab, Gdk::KEY_dead_grave})
      view_manager = @view_manager
      return Gdk::EVENT_PROPAGATE if view_manager.nil?

      view_manager.rotate_views(reverse: key_val == Gdk::KEY_dead_grave)
      return Gdk::EVENT_STOP
    end
    Gdk::EVENT_PROPAGATE
  end

  def key_released(key_val : UInt32, key_code : UInt32, modifier : Gdk::ModifierType) : Bool
    view_manager = @view_manager
    return Gdk::EVENT_PROPAGATE if view_manager.nil?

    if modifier.control_mask?
      return Gdk::EVENT_STOP if key_val.in?({Gdk::KEY_Tab, Gdk::KEY_dead_grave})

      view_manager.stop_rotate
    end
    Gdk::EVENT_PROPAGATE
  end

  def with_current_view
    view_manager = @view_manager
    return if view_manager.nil?

    view = view_manager.current_view?
    yield(view) if view
  end

  def save_current_view
    with_current_view do |view|
      return unless view.is_a?(DocumentView)

      if view.resource.nil?
        save_current_view_as
      else
        view.save if view.modified?
      end
    end
  end

  def save_current_view_as
    with_current_view do |view|
      next unless view.is_a?(DocumentView)

      dialog = Gtk::FileChooserNative.new("Save File", self, :save, "_Spen", "_Cancel")
      dialog.response_signal.connect do |response|
        if Gtk::ResponseType.from_value(response).accept?
          path = dialog.file.try(&.path)
          view.save_as(path) if path
        end
        dialog.destroy
      end

      dialog.show
    end
  end

  private def reload_current_view
    with_current_view do |view|
      view.reload_contents if view.is_a?(DocumentView)
    end
  end

  private def close_current_view : Nil
    with_current_view do |view|
      if view.is_a?(DocumentView) && view.modified?
        dlg = SaveModifiedViewsDialog.new(self, [view])
        dlg.present do
          view_manager.remove_current_view
        end
      else
        view_manager.remove_current_view
      end
    end
  end

  private def close_all_views : Nil
    view_manager = @view_manager
    return if view_manager.nil?

    modified_views = view_manager.modified_views
    if modified_views.empty?
      view_manager.remove_all_views
      return
    end

    dlg = SaveModifiedViewsDialog.new(self, modified_views)
    dlg.present do
      view_manager.remove_all_views
    end
  end

  def show_open_file_dialog
    # FIXME: Something is storing `dialog` address and not letting it be garbage collected
    dialog = Gtk::FileChooserNative.new("Open File", self, :open, "_Open", "_Cancel")

    dialog.response_signal.connect do |response|
      if Gtk::ResponseType.from_value(response).accept?
        path = dialog.file.try(&.path)
        open(path) if path
      end
      dialog.destroy
    end

    dialog.show
  end

  def new_file
    view_manager.add_view(TextView.new)
  end

  def new_terminal
    {% unless flag?(:no_terminal) %}
      view_manager.add_view(TerminalView.new)
    {% end %}
  end

  def open(variant : GLib::Variant)
    open(variant.as_s)
  end

  def open(resource : String) : Nil
    open(Path.new(resource))
  end

  def open(resource : Path) : Nil
    view_manager = @view_manager
    if view_manager.nil?
      open_project(resource)
      return
    end

    view = view_manager.find_view_by_resource(resource)
    if view.nil?
      view = ViewFactory.build(resource, @project)
      view_manager.add_view(view)
    else
      view_manager.show_view(view, reorder: true, focus: true)
    end
  rescue e : IO::Error
    application.error(e)
  end

  private def show_locator
    return if @view_manager.nil?

    @locator.show(select_text: true, view: view_manager.current_view?)
  end

  private def show_goto_line_locator
    return if @view_manager.nil?

    with_current_view do |view|
      if view.is_a?(DocumentView)
        @locator.text = "l "
        @locator.show(select_text: false, view: view)
      end
    end
  end

  private def goto_line(variant : GLib::Variant?)
    line, col, path = variant.as_s.split(":", 3)
    open(path) unless path.blank?
    goto_line(line.to_i, col.to_i)
  end

  private def goto_line(line : Int32, col : Int32)
    with_current_view do |view|
      view.goto_line(line, col) if view.is_a?(DocumentView)
      view.grab_focus
    end
  end

  private def copy_to_clipboard
    with_current_view(&.copy_to_clipboard)
  end

  private def paste_from_clipboard
    with_current_view(&.paste_from_clipboard)
  end

  {% for action in %w(sort_lines
                     comment_code
                     move_lines_up move_lines_down
                     move_viewport_line_up move_viewport_line_down
                     move_viewport_page_up move_viewport_page_down
                     find find_next find_prev goto_definition) %}
  private def {{ action.id }}
    with_current_view do |view|
      view.{{ action.id }} if view.responds_to?({{ action.id.symbolize }})
    end
  end
  {% end %}

  def maximize_view
    with_current_view do |view|
      view_manager.maximize_view(view)
    end
  end

  def change_git_branch(variant : GLib::Variant)
    branch_name = variant.as_s
    system("git checkout #{branch_name}")
    change_action_state("change_git_branch", variant)
  end

  private def toggle_fullscreen
    header = Gtk::Widget.cast(template_child("header"))
    if fullscreened?
      header.visible = true
      unfullscreen
    else
      header.visible = false
      fullscreen
    end
  end

  private def on_window_active_changed(_spec)
    with_current_view do |view|
      return unless view.is_a?(DocumentView)

      view.check_for_external_changes
    end
  end

  def color_scheme=(scheme)
    @view_manager.try(&.color_scheme=(scheme))
  end
end
