-- Copyright 2012-2015 The Howl Developers
-- License: MIT (see LICENSE.md at the top-level directory of the distribution)

import app, interact from howl

class ReadText
  run: (@finish, opts = {}) =>
    with app.window.command_line
      .prompt = opts.prompt or ''
      .title = opts.title
    @opts = moon.copy opts

  keymap:
    enter: =>
      self.finish app.window.command_line.text

    escape: => self.finish!

  handle_back: =>
    if @opts.cancel_on_back
      self.finish back: true

interact.register
  name: 'read_text'
  description: 'Read free form text entered by user'
  factory: ReadText

