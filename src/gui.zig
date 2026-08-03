// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Comptime feature dispatcher for emojig GUI subsystem.
//! Selects the real native GUI engine when -Dgui=true (default),
//! or the zero-dependency headless stub when -Dgui=false.

const std = @import("std");
const build_options = @import("build_options");

/// Compile-time feature flag indicating if native GUI support is compiled in.
pub const is_gui_enabled: bool = if (@hasDecl(build_options, "enable_gui")) build_options.enable_gui else true;

/// Dispatcher: lazily imports src/gui/stub.zig when -Dgui=false to avoid
/// parsing or linking GUI headers/libraries.
pub const stub = @import("gui/stub.zig");
