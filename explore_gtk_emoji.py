#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Uwe Jugel
# SPDX-License-Identifier: MIT
"""Explore GTK4 built-in emoji picker (Ctrl+. in text fields)."""

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk


class EmojiExplorer(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="GTK4 Emoji Picker Explorer")
        self.set_default_size(400, 200)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_margin_top(24)
        box.set_margin_bottom(24)
        box.set_margin_start(24)
        box.set_margin_end(24)

        label = Gtk.Label(label="Press Ctrl+. to open the GTK emoji picker:")
        label.set_halign(Gtk.Align.START)
        box.append(label)

        self.entry = Gtk.Entry()
        self.entry.set_placeholder_text("Type here, then press Ctrl+. …")
        box.append(self.entry)

        self.text_view = Gtk.TextView()
        self.text_view.set_wrap_mode(Gtk.WrapMode.WORD)
        scroll = Gtk.ScrolledWindow()
        scroll.set_child(self.text_view)
        scroll.set_vexpand(True)
        box.append(scroll)

        hint = Gtk.Label(label="Both the Entry and TextView support Ctrl+.")
        hint.add_css_class("dim-label")
        hint.set_halign(Gtk.Align.START)
        box.append(hint)

        self.set_child(box)
        self.entry.grab_focus()


def on_activate(app):
    win = EmojiExplorer(app)
    win.present()


app = Gtk.Application(application_id="com.example.EmojiExplorer")
app.connect("activate", on_activate)
app.run(None)
