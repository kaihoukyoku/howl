-- Copyright 2012-2013 Nils Nordman <nino at nordman.org>
-- License: MIT (see LICENSE.md)

import Gtk from lgi
import Scintilla, Completer, signal, keyhandler, config, command from howl
import PropertyObject from howl.aux.moon
import style, highlight, theme, IndicatorBar, Cursor, Selection from howl.ui
import Searcher, CompletionPopup from howl.ui
import destructor from howl.aux

_editors = setmetatable {}, __mode: 'v'
editors = -> [e for _, e in pairs _editors when e != nil]

indicators = {}
indicator_placements =
  top_left: true
  top_right: true
  bottom_left: true
  bottom_right: true

apply_variable = (method, value) ->
  for e in *editors!
    sci = e.sci
    sci[method] sci, value

apply_property = (name, value) ->
  e[name] = value for e in *editors!

class Editor extends PropertyObject

  register_indicator: (id, placement = 'bottom_right') ->
    if not indicator_placements[placement]
      error('Illegal placement "' .. placement .. '"', 2)

    indicators[id] = :id, :placement

  unregister_indicator: (id) ->
    e\_remove_indicator id for e in *editors!
    indicators[id] = nil

  new: (buffer) =>
    error('Missing argument #1 (buffer)', 2) if not buffer
    super!

    @indicator = setmetatable {}, __index: self\_create_indicator

    @sci = Scintilla!

    style.register_sci @sci
    theme.register_sci @sci

    listener =
      on_style_needed: self\_on_style_needed
      on_keypress: self\_on_keypress
      on_selection_changed: self\_on_selection_changed
      on_changed: self\_on_changed
      on_focus: self\_on_focus
      on_focus_lost: self\_on_focus_lost
      on_char_added: self\_on_char_added
      on_text_inserted: self\_on_text_inserted
      on_text_deleted: self\_on_text_deleted
      on_error: log.error

    @sci.listener = listener

    @selection = Selection @sci
    @cursor = Cursor self, @selection
    @searcher = Searcher self
    @completion_popup = CompletionPopup self

    @header = IndicatorBar 'header', 3
    @footer = IndicatorBar 'footer', 3

    @bin = Gtk.EventBox {
      Gtk.Alignment {
        top_padding: 1,
        left_padding: 1,
        right_padding: 3,
        bottom_padding: 3,
        Gtk.Box {
          orientation: 'VERTICAL',
          @header\to_gobject!
          {
            expand: true
            Gtk.EventBox {
              id: 'sci_box'
              Gtk.Alignment {
                top_padding: 1
                bottom_padding: 1
                @sci\to_gobject!
              }
            }
          }
          @footer\to_gobject!
        }
      }
    }
    @bin\get_style_context!\add_class 'editor'
    @bin.child.sci_box\get_style_context!\add_class 'sci_box'
    @bin.can_focus = true
    @bin.on_focus_in_event = -> @sci\grab_focus!
    @bin.on_destroy = -> @buffer\remove_sci_ref @sci

    @buffer = buffer

    append _editors, self

    signal.connect 'buffer-saved', (args) ->
      @remove_popup! if @buffer == args.buffer

    signal.connect 'buffer-title-set', (args) ->
      buffer = args.buffer
      @indicator.title.label = buffer.title if @buffer == buffer

  to_gobject: => @bin

  @property buffer:
    get: => @_buf
    set: (buffer) =>
      signal.emit 'before-buffer-switch', editor: self, current_buffer: @_buf, new_buffer: buffer
      @selection\remove!

      if @_buf
        @_buf.properties.position = @cursor.pos
        @_buf\remove_sci_ref @sci

      prev_buffer = @_buf
      @_buf = buffer
      @indicator.title.label = buffer.title
      @sci\set_doc_pointer(buffer.doc)

      @_set_config_settings!
      style.set_for_buffer @sci, buffer
      highlight.set_for_buffer @sci, buffer
      buffer\add_sci_ref @sci

      pos = buffer.properties.position or 1
      pos = math.max 1, math.min pos, #buffer
      @cursor.pos = pos
      signal.emit 'after-buffer-switch', editor: self, current_buffer: buffer, old_buffer: prev_buffer

  @property current_line: get: => @buffer.lines[@cursor.line]
  @property current_context: get: => @buffer\context_at @cursor.pos

  @property indentation_guides:
    get: =>
      sci_val = @sci\get_indentation_guides!
      switch sci_val
        when Scintilla.SC_IV_NONE then 'none'
        when Scintilla.SC_IV_REAL then 'real'
        when Scintilla.SC_IV_LOOKBOTH then 'on'
        else '(unknown)'

    set: (value) =>
      sci_value = switch value
        when 'none' then Scintilla.SC_IV_NONE
        when 'real' then Scintilla.SC_IV_REAL
        when 'on' then Scintilla.SC_IV_LOOKBOTH
      error "Unknown value for indentation_guides: #{value}", 2 unless sci_value
      @sci\set_indentation_guides sci_value

  @property line_wrapping:
    get: =>
      sci_val = @sci\get_wrap_mode!
      switch sci_val
        when Scintilla.SC_WRAP_NONE then 'none'
        when Scintilla.SC_WRAP_WORD then 'word'
        when Scintilla.SC_WRAP_CHAR then 'character'
        else '(unknown)'

    set: (value) =>
      sci_value = switch value
        when 'none' then Scintilla.SC_WRAP_NONE
        when 'word' then Scintilla.SC_WRAP_WORD
        when 'character' then Scintilla.SC_WRAP_CHAR
      error "Unknown value for line_wrapping: #{value}", 2 unless sci_value
      @sci\set_wrap_mode sci_value

  @property caret_line_highlighted:
    get: => @sci\get_caret_line_visible!
    set: (flag) => @sci\set_caret_line_visible flag

  @property horizontal_scrollbar:
    get: => @sci\get_hscroll_bar!
    set: (flag) => @sci\set_hscroll_bar flag

  @property vertical_scrollbar:
    get: => @sci\get_vscroll_bar!
    set: (flag) => @sci\set_vscroll_bar flag

  @property overtype:
    get: => @sci\get_overtype!
    set: (flag) => @sci\set_overtype flag

  @property lines_on_screen:
    get: => @sci\lines_on_screen!

  @property line_numbers:
    get: => @sci\get_margin_width_n(0) > 0
    set: (flag) =>
      width = flag and 4 + 4 * @sci\text_width(Scintilla.STYLE_LINENUMBER, '9') or 0
      @sci\set_margin_width_n 0, width

  @property active_lines: get: =>
    return if @selection.empty
      { @current_line }
    else
      @buffer.lines\for_text_range @selection.anchor, @cursor.pos

  @property active_chunk: get: =>
    return if @selection.empty
      @buffer\chunk 1, @buffer.length
    else
      start, stop = @selection\range!
      @buffer\chunk start, stop

  grab_focus: => @sci\grab_focus!
  newline: => @buffer\as_one_undo -> @sci\new_line!

  shift_right: =>
    if @selection.empty
      column = @cursor.column
      @current_line\indent!
      @cursor.column = column + @buffer.config.indent
    else
      @sci\tab!

  shift_left: =>
    if @selection.empty
      column = @cursor.column
      if @current_line.indentation > 0
        @current_line\unindent!
        @cursor.column = math.max(column - @buffer.config.indent, 0)
    else
      @sci\back_tab!

  transform_active_lines: (f) =>
    lines = @active_lines
    @buffer\as_one_undo -> f lines

  indent: => if @buffer.mode.indent then @buffer.mode\indent self
  comment: => if @buffer.mode.comment then @buffer.mode\comment self
  uncomment: => if @buffer.mode.uncomment then @buffer.mode\uncomment self
  toggle_comment: => if @buffer.mode.toggle_comment then @buffer.mode\toggle_comment self

  delete_line: => @sci\line_delete!

  delete_to_end_of_line: (no_copy) =>
    if no_copy
      @sci\del_line_right!
    else
      cur_line = @current_line
      end_pos = cur_line.end_pos
      end_pos -= 1 if cur_line.next
      @selection\select @cursor.pos, end_pos
      @selection\cut!

  copy_line: => @sci\line_copy!
  paste: => @sci\paste!
  insert: (text) => @sci\add_text #text, text
  smart_tab: => @sci\tab!
  smart_back_tab: => @sci\back_tab!
  delete_back: => @sci\delete_back!

  join_lines: =>
    @buffer\as_one_undo ->
      cur_line = @current_line
      next_line = cur_line.next
      return unless next_line
      @cursor\line_end!
      target_pos = @cursor.pos
      content_start = next_line\ufind('[^%s]') or 1
      @buffer\delete target_pos, next_line.start_pos + content_start - 2
      @buffer\insert ' ', target_pos

  duplicate_current: => @sci\selection_duplicate!

  forward_to_match: (str) =>
    pos = @current_line\ufind str, @cursor.column_index + 1, true
    @cursor.column_index = pos if pos

  backward_to_match: (str) =>
    rev_line = @current_line.text.ureverse
    cur_column = (rev_line.ulen - @cursor.column_index + 1)
    pos = rev_line\ufind str, cur_column + 1, true
    @cursor.column_index = (rev_line.ulen - pos) + 1 if pos

  show_popup: (popup, options = {}) =>
    char_width = @sci\text_width 32, ' '
    char_height = @sci\text_height 0

    x_adjust = 0
    pos = options.position
    pos = @cursor.pos if not pos
    pos = @buffer\byte_offset pos

    line = @sci\line_from_position pos - 1
    at_eol = @sci\get_line_end_position(line) == pos - 1

    if at_eol
      pos -= 1
      x_adjust = char_width

    x = @sci\point_xfrom_position(pos) + x_adjust
    y = @sci\point_yfrom_position pos

    x -= char_width
    y += char_height + 2

    popup\show @sci\to_gobject!, :x, :y
    @popup = window: popup, :options

  remove_popup: =>
    if @popup
      @popup.window\close!
      @popup = nil

  complete: =>
    @completion_popup\complete!
    if not @completion_popup.empty
      @show_popup @completion_popup, position: @completion_popup.position, persistent: true

  undo: => @buffer\undo!
  redo: => @buffer\redo!
  scroll_up: => @sci\line_scroll_up!
  scroll_down: => @sci\line_scroll_down!

  -- private
  _set_config_settings: =>
    buf = @buffer
    config = buf.config
    with @sci
      \set_tab_width config.tab_width
      \set_use_tabs config.use_tabs
      \set_indent config.indent
      \set_tab_indents config.tab_indents
      \set_back_space_un_indents config.backspace_unindents
      \set_wrap_visual_flags Scintilla.SC_WRAPVISUALFLAG_END

    with config
      @indentation_guides = .indentation_guides
      @line_wrapping = .line_wrapping
      @horizontal_scrollbar = .horizontal_scrollbar
      @vertical_scrollbar = .vertical_scrollbar
      @caret_line_highlighted = .caret_line_highlighted
      @line_numbers = .line_numbers

  _create_indicator: (indics, id) =>
    def = indicators[id]
    error 'Invalid indicator id "' .. id .. '"', 2 if not def
    y, x = def.placement\match('^(%w+)_(%w+)$')
    bar = y == 'top' and @header or @footer
    indic = bar\add x, id
    indics[id] = indic
    indic

  _remove_indicator: (id) =>
    def = indicators[id]
    return unless def
    y, x = def.placement\match('^(%w+)_(%w+)$')
    bar = y == 'top' and @header or @footer
    bar\remove id
    @indicator[id] = nil

  _on_style_needed: (...) =>
    @buffer\lex ...

  _on_keypress: (event) =>
    @remove_popup! if event.key_name == 'escape'

    if @popup
      if not @popup.window.showing
        @remove_popup!
      else
        if @popup.window.keymap
          return true if keyhandler.dispatch event, { @popup.window.keymap }, @popup.window

        @remove_popup! if not @popup.options.persistent
    else
      @searcher\cancel!

    keyhandler.process self, event

  _on_selection_changed: =>
    @_update_position!
    @_brace_highlight!
    signal.emit 'selection-changed', editor: self, selection: @selection

  _on_changed: =>
    @_update_position!
    @_brace_highlight!
    signal.emit 'editor-changed', editor: self

  _brace_highlight: =>
    should_highlight = @buffer.config.matching_braces_highlighted

    if should_highlight
      current_pos = @sci\get_current_pos!
      matching_pos = @sci\brace_match current_pos
      if matching_pos < 0
        is_brace = @current_context.suffix\find '^[][()<>{}]'
        if is_brace
          @sci\brace_bad_light current_pos
          @_brace_highlighted = true
        else
          matching_pos = @sci\brace_match current_pos - 1

      if matching_pos >= 0
        @sci\brace_highlight current_pos, matching_pos
        @_brace_highlighted = true
        return

    if @_brace_highlighted
      @sci\brace_highlight -1, -1
      @_brace_highlighted = false

  _update_position: =>
    pos = @cursor.line .. ':' .. @cursor.column
    @indicator.position.label = pos

  _on_focus: (args) =>
    _G.editor = self
    @cursor.pos = @cursor.pos -- this ensures cursor is visible
    signal.emit 'editor-focused', editor: self
    false

  _on_focus_lost: (args) =>
    @remove_popup!
    signal.emit 'editor-defocused', editor: self
    false

  _on_char_added: (args) =>
    params = moon.copy args
    params.editor = self
    return if signal.emit 'character-added', params
    return if @buffer.mode.on_char_added and @buffer.mode\on_char_added params, self

    if @popup
      @popup.window\on_char_added self, params if @popup.window.on_char_added
    else
      complete_allowed = @buffer.config.complete != 'manual'
      if complete_allowed and #@current_context.word_prefix >= config.completion_popup_after
        @complete!
        true

  _on_text_inserted: (args) =>
    @buffer.sci_listener.on_text_inserted args
    signal_params = moon.copy args
    signal_params.editor = self
    signal_params.lines_added = args.lines_affected
    handled = signal.emit 'text-inserted', signal_params

    if @popup
      @popup.window\on_text_inserted self, signal_params if @popup.window.on_text_inserted

  _on_text_deleted: (args) =>
    @buffer.sci_listener.on_text_deleted args
    signal_params = moon.copy args
    signal_params.editor = self
    signal_params.lines_deleted = args.lines_affected
    handled = signal.emit 'text-deleted', signal_params

    if @popup
      @popup.window\on_text_deleted self, args if @popup.window.on_text_deleted

-- Default indicators

with Editor
  .register_indicator 'title', 'top_left'
  .register_indicator 'position', 'bottom_right'

-- Config variables

with config
  .define
    name: 'tab_width'
    description: 'The width of a tab, in number of characters'
    default: 8
    type_of: 'number'

  .define
    name: 'use_tabs'
    description: 'Whether to use tabs for indentation, and not only spaces'
    default: false
    type_of: 'boolean'

  .define
    name: 'indent'
    description: 'The number of characters to use for indentation'
    default: 2
    type_of: 'number'

  .define
    name: 'tab_indents'
    description: 'Whether tab indents within whitespace'
    default: true
    type_of: 'boolean'

  .define
    name: 'backspace_unindents'
    description: 'Whether backspace unindents within whitespace'
    default: true
    type_of: 'boolean'

  .define
    name: 'completion_popup_after'
    description: 'Show completion after this many characters'
    default: 2
    type_of: 'number'

  .define
    name: 'indentation_guides'
    description: 'Controls how indentation guides are shown'
    default: 'on'
    options: {
      { 'none', 'No indentation guides are shown' }
      { 'real', 'Indentation guides are shown inside real indentation white space' }
      { 'on', 'Indentation guides are shown' }
    }

  .define
    name: 'line_wrapping'
    description: 'Controls how lines are wrapped if neccessary'
    default: 'word'
    options: {
      { 'none', 'Lines are not wrapped' }
      { 'word', 'Lines are wrapped on word boundaries' }
      { 'character', 'Lines are wrapped on character boundaries' }
    }

  .define
    name: 'horizontal_scrollbar'
    description: 'Whether horizontal scrollbars are shown'
    default: false
    type_of: 'boolean'

  .define
    name: 'vertical_scrollbar'
    description: 'Whether vertical scrollbars are shown'
    default: true
    type_of: 'boolean'

  .define
    name: 'caret_line_highlighted'
    description: 'Whether the caret line is highlighted'
    default: true
    type_of: 'boolean'

  .define
    name: 'matching_braces_highlighted'
    description: 'Whether matching braces are highlighted'
    default: true
    type_of: 'boolean'

  .define
    name: 'line_numbers'
    description: 'Whether line numbers are shown'
    default: true
    type_of: 'boolean'

  .define
    name: 'cursor_blink_interval'
    description: 'The rate at which the cursor blinks (ms, 0 disables)'
    default: 500
    type_of: 'number'

  for watched_property in *{
    'indentation_guides',
    'line_wrapping',
    'horizontal_scrollbar',
    'vertical_scrollbar',
    'caret_line_highlighted',
    'line_numbers',
  }
    .watch watched_property, apply_property

  for live_update in *{
    { 'tab_width', 'set_tab_width' }
    { 'use_tabs', 'set_use_tabs' }
    { 'indent', 'set_indent' }
    { 'tab_indents', 'set_tab_indents' }
    { 'backspace_unindents', 'set_back_space_un_indents' }
    { 'cursor_blink_interval', 'set_caret_period' }

  }
    .watch live_update[1], (_, value) -> apply_variable live_update[2], value

-- Commands
for cmd_spec in *{
  { 'newline', 'Adds a new line at the current position', 'newline' }
  { 'newline-and-format', 'Adds a new line, and formats as needed', 'newline_and_format' }
  { 'comment', 'Comments the selection or current line', 'comment' }
  { 'uncomment', 'Uncomments the selection or current line', 'uncomment' }
  { 'toggle_comment', 'Comments or uncomments the selection or current line', 'toggle_comment' }
  { 'delete-line', 'Deletes the current line', 'delete_line' }
  { 'cut-to-end-of-line', 'Cuts to the end of line', 'delete_to_end_of_line' }
  { 'delete-to-end-of-line', 'Deletes to the end of line', 'delete_to_end_of_line', true }
  { 'copy-line', 'Copies the current line to the clipboard', 'copy_line' }
  { 'paste', 'Pastes the contents of the clipboard at the current position', 'paste' }
  { 'smart-tab', 'Inserts tab or shifts selected text right', 'smart_tab' }
  { 'smart-back-tab', 'Moves to previous tab stop or shifts text left', 'smart_back_tab' }
  { 'delete-back', 'Deletes one character back', 'delete_back' }
  { 'shift-right', 'Shifts the selected lines, or the current line, right', 'shift_right' }
  { 'shift-left', 'Shifts the selected lines, or the current line, left', 'shift_left' }
  { 'indent', 'Indents the selected lines, or the current line', 'indent' }
  { 'join-lines', 'Joins the current line with the line below', 'join_lines' }
  { 'complete', 'Starts completion at cursor', 'complete' }
  { 'undo', 'Undo last edit for the current editor', 'undo' }
  { 'redo', 'Redo last undo for the current editor', 'redo' }
  { 'scroll-up', 'Scrolls one line up', 'scroll_up' }
  { 'scroll-down', 'Scrolls one line down', 'scroll_down' }
  { 'duplicate-current', 'Duplicates the selection or current line', 'duplicate_current' }
}
  args = { select 4, table.unpack cmd_spec }
  command.register
    name: "editor-#{cmd_spec[1]}"
    description: cmd_spec[2]
    handler: -> _G.editor[cmd_spec[3]] _G.editor, table.unpack args

for sel_cmd_spec in *{
  { 'copy', 'Copies the current selection to the clipboard' }
  { 'cut', 'Cuts the current selection to the clipboard' }
  { 'select-all', 'Cuts the current selection to the clipboard' }
}
  command.register
    name: "editor-#{sel_cmd_spec[1]}"
    description: sel_cmd_spec[2]
    handler: -> _G.editor.selection[sel_cmd_spec[1]\gsub '-', '_'] _G.editor.selection

-- signals

signal.register 'editor-changed',
  description: [[Signaled when the editor has been changed in some way.
This could be the result of the text, or the styling of the text being changed,
or it could also be that the selection or scroll position has changed.
]]
  parameters:
    editor: 'The editor for which the change occurred'

signal.register 'before-buffer-switch',
  description: 'Signaled right before a buffer is set for an editor'
  parameters:
    editor: 'The editor for which the buffer is being set'
    current_buffer: 'The current buffer for the editor'
    new_buffer: 'The new buffer that will be set for the editor'

signal.register 'after-buffer-switch',
  description: 'Signaled right after a buffer has been set for an editor'
  parameters:
    editor: 'The editor for which the buffer was set'
    current_buffer: 'The new buffer that was set for the editor'
    old_buffer: 'The buffer that was previously set for the editor'

signal.register 'editor-focused',
  description: 'Signaled right after an editor has recieved focus'
  parameters:
    editor: 'The editor that recieved focus'

signal.register 'editor-defocused',
  description: 'Signaled right after an editor has lost focus'
  parameters:
    editor: 'The editor that lost focus'

signal.register 'character-added',
  description: 'Signaled when a character has been typed into an editor'
  parameters:
    editor: 'The editor that received the character'
    key_code: 'The unique numeric code for the key pressed'
    key_name: "A string representation of the key's name, if available"
    character: 'A string representation of the key pressed, if available'
    control: 'A boolean indicating whether the control key was held down'
    shift: 'A boolean indicating whether the shift key was held down'
    alt: 'A boolean indicating whether the alt key was held down'
    super: 'A boolean indicating whether the super key was held down'
    meta: 'A boolean indicating whether the meta key was held down'

signal.register 'text-inserted',
  description: 'Signaled right after text has been inserted into an editor'
  parameters:
    editor: 'The editor for which the text was inserted'
    position: 'The start position of the inserted text'
    length: 'The number of characters in the inserted text'
    text: 'The text that was inserted'
    lines_added: 'The number of lines that were added'

signal.register 'text-deleted',
  description: 'Signaled right after text was deleted from the editor'
  parameters:
    editor: 'The editor for which the text was inserted'
    position: 'The start position of the deleted text'
    length: 'The number of characters that was deleted'
    text: 'The text that was deleted'
    lines_deleted: 'The number of lines that were deleted'

return Editor
