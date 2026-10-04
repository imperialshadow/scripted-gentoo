#!/usr/bin/env python3
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
"""
wormhole-gui — GTK3 frontend for magic-wormhole
"""
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Gdk, Pango
import subprocess
import threading
import os
import re

WORMHOLE = "/usr/local/bin/wormhole"


class WormholeGUI(Gtk.Window):
    def __init__(self):
        super().__init__(title="Wormhole File Transfer")
        self.set_default_size(580, 480)
        self.set_border_width(0)
        self.connect("destroy", Gtk.main_quit)

        self._proc = None
        self._send_file = None
        self._recv_dir = os.path.expanduser("~")

        nb = Gtk.Notebook()
        self.add(nb)
        nb.append_page(self._build_send(), Gtk.Label(label="  Send  "))
        nb.append_page(self._build_receive(), Gtk.Label(label="  Receive  "))

    # ── Send tab ──────────────────────────────────────────────────────────────

    def _build_send(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        vbox.set_border_width(14)

        # File picker row
        file_row = Gtk.Box(spacing=8)
        choose_btn = Gtk.Button(label="Choose File…")
        choose_btn.connect("clicked", self._on_choose_file)
        self._send_file_label = Gtk.Label(label="No file selected")
        self._send_file_label.set_xalign(0)
        self._send_file_label.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        file_row.pack_start(choose_btn, False, False, 0)
        file_row.pack_start(self._send_file_label, True, True, 0)
        vbox.pack_start(file_row, False, False, 0)

        # Code display
        code_frame = Gtk.Frame(label=" Wormhole Code ")
        code_inner = Gtk.Box(spacing=8)
        code_inner.set_border_width(10)
        self._code_label = Gtk.Label(label="—")
        self._code_label.set_selectable(True)
        attrs = Pango.AttrList()
        attrs.insert(Pango.attr_family_new("Monospace"))
        attrs.insert(Pango.attr_scale_new(1.5))
        attrs.insert(Pango.attr_weight_new(Pango.Weight.BOLD))
        self._code_label.set_attributes(attrs)
        copy_btn = Gtk.Button(label="Copy")
        copy_btn.connect("clicked", self._on_copy_code)
        code_inner.pack_start(self._code_label, True, True, 0)
        code_inner.pack_start(copy_btn, False, False, 0)
        code_frame.add(code_inner)
        vbox.pack_start(code_frame, False, False, 0)

        # Status + buttons
        status_row = Gtk.Box(spacing=8)
        self._send_status = Gtk.Label(label="Ready")
        self._send_status.set_xalign(0)
        self._send_btn = Gtk.Button(label="Send")
        self._send_btn.get_style_context().add_class("suggested-action")
        self._send_btn.set_sensitive(False)
        self._send_btn.connect("clicked", self._on_send)
        self._send_cancel_btn = Gtk.Button(label="Cancel")
        self._send_cancel_btn.set_sensitive(False)
        self._send_cancel_btn.connect("clicked", self._on_cancel)
        status_row.pack_start(self._send_status, True, True, 0)
        status_row.pack_start(self._send_cancel_btn, False, False, 0)
        status_row.pack_start(self._send_btn, False, False, 0)
        vbox.pack_start(status_row, False, False, 0)

        # Output log
        self._send_buf, sw = self._make_log()
        vbox.pack_start(sw, True, True, 0)

        return vbox

    # ── Receive tab ───────────────────────────────────────────────────────────

    def _build_receive(self):
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        vbox.set_border_width(14)

        # Code entry
        code_row = Gtk.Box(spacing=8)
        code_row.pack_start(Gtk.Label(label="Code:"), False, False, 0)
        self._code_entry = Gtk.Entry()
        self._code_entry.set_placeholder_text("e.g.  7-crossword-clockwork")
        self._code_entry.connect("activate", self._on_receive)
        code_row.pack_start(self._code_entry, True, True, 0)
        vbox.pack_start(code_row, False, False, 0)

        # Save directory
        dir_row = Gtk.Box(spacing=8)
        dir_row.pack_start(Gtk.Label(label="Save to:"), False, False, 0)
        self._recv_dir_label = Gtk.Label(label=self._recv_dir)
        self._recv_dir_label.set_xalign(0)
        self._recv_dir_label.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        dir_btn = Gtk.Button(label="Choose…")
        dir_btn.connect("clicked", self._on_choose_dir)
        dir_row.pack_start(self._recv_dir_label, True, True, 0)
        dir_row.pack_start(dir_btn, False, False, 0)
        vbox.pack_start(dir_row, False, False, 0)

        # Status + buttons
        status_row = Gtk.Box(spacing=8)
        self._recv_status = Gtk.Label(label="Ready")
        self._recv_status.set_xalign(0)
        self._recv_btn = Gtk.Button(label="Receive")
        self._recv_btn.get_style_context().add_class("suggested-action")
        self._recv_btn.connect("clicked", self._on_receive)
        self._recv_cancel_btn = Gtk.Button(label="Cancel")
        self._recv_cancel_btn.set_sensitive(False)
        self._recv_cancel_btn.connect("clicked", self._on_cancel)
        status_row.pack_start(self._recv_status, True, True, 0)
        status_row.pack_start(self._recv_cancel_btn, False, False, 0)
        status_row.pack_start(self._recv_btn, False, False, 0)
        vbox.pack_start(status_row, False, False, 0)

        # Output log
        self._recv_buf, sw = self._make_log()
        vbox.pack_start(sw, True, True, 0)

        return vbox

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _make_log(self):
        buf = Gtk.TextBuffer()
        tv = Gtk.TextView(buffer=buf)
        tv.set_editable(False)
        tv.set_monospace(True)
        tv.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.add(tv)
        return buf, sw

    def _append_log(self, buf, text):
        it = buf.get_end_iter()
        buf.insert(it, text + "\n")

    # ── Event handlers ────────────────────────────────────────────────────────

    def _on_choose_file(self, _btn):
        dlg = Gtk.FileChooserDialog(
            title="Choose file to send", parent=self,
            action=Gtk.FileChooserAction.OPEN)
        dlg.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                        Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        if dlg.run() == Gtk.ResponseType.OK:
            self._send_file = dlg.get_filename()
            self._send_file_label.set_text(os.path.basename(self._send_file))
            self._send_btn.set_sensitive(True)
        dlg.destroy()

    def _on_choose_dir(self, _btn):
        dlg = Gtk.FileChooserDialog(
            title="Choose save location", parent=self,
            action=Gtk.FileChooserAction.SELECT_FOLDER)
        dlg.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                        Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        dlg.set_filename(self._recv_dir)
        if dlg.run() == Gtk.ResponseType.OK:
            self._recv_dir = dlg.get_filename()
            self._recv_dir_label.set_text(self._recv_dir)
        dlg.destroy()

    def _on_copy_code(self, _btn):
        code = self._code_label.get_text()
        if code and code != "—":
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(code, -1)

    def _on_send(self, _btn):
        if not self._send_file:
            return
        self._send_buf.set_text("")
        self._code_label.set_text("—")
        self._send_btn.set_sensitive(False)
        self._send_cancel_btn.set_sensitive(True)
        self._send_status.set_text("Sending…")
        threading.Thread(
            target=self._run,
            args=([WORMHOLE, "send", self._send_file],
                  self._send_buf, self._send_btn, self._send_cancel_btn,
                  self._send_status, True),
            daemon=True,
        ).start()

    def _on_receive(self, _widget):
        code = self._code_entry.get_text().strip()
        if not code:
            return
        self._recv_buf.set_text("")
        self._recv_btn.set_sensitive(False)
        self._recv_cancel_btn.set_sensitive(True)
        self._recv_status.set_text("Receiving…")
        threading.Thread(
            target=self._run,
            args=([WORMHOLE, "receive", code],
                  self._recv_buf, self._recv_btn, self._recv_cancel_btn,
                  self._recv_status, False),
            kwargs={"cwd": self._recv_dir},
            daemon=True,
        ).start()

    def _on_cancel(self, _btn):
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    # ── Subprocess runner (background thread) ─────────────────────────────────

    def _run(self, cmd, buf, run_btn, cancel_btn, status_lbl, is_send, cwd=None):
        try:
            self._proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.PIPE,
                text=True,
                cwd=cwd,
            )
            # Answer any "ok? (Y/n)" prompt automatically on receive
            if not is_send:
                try:
                    self._proc.stdin.write("y\n")
                    self._proc.stdin.flush()
                    self._proc.stdin.close()
                except OSError:
                    pass

            for line in self._proc.stdout:
                line = line.rstrip()
                GLib.idle_add(self._append_log, buf, line)
                if is_send:
                    m = re.search(r"Wormhole code is: (\S+)", line)
                    if m:
                        GLib.idle_add(self._code_label.set_text, m.group(1))

            rc = self._proc.wait()
            final = "Transfer complete." if rc == 0 else f"Failed (exit {rc})."
        except FileNotFoundError:
            GLib.idle_add(self._append_log, buf,
                          f"ERROR: wormhole not found at {WORMHOLE}\n"
                          "Run gentoo-wormhole.sh to install it.")
            final = "Error."
        finally:
            GLib.idle_add(status_lbl.set_text, final)
            GLib.idle_add(run_btn.set_sensitive, True)
            GLib.idle_add(cancel_btn.set_sensitive, False)
            if is_send:
                GLib.idle_add(self._send_btn.set_sensitive,
                              self._send_file is not None)


if __name__ == "__main__":
    win = WormholeGUI()
    win.show_all()
    Gtk.main()
