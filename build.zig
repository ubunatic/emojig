// SPDX-FileCopyrightText: 2026 Uwe Jugel
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // LLVM's optimizer is the slow part of `make install` (-Doptimize=ReleaseSmall),
    // not linking: zig's native ELF path already uses its own fast self-hosted
    // linker, so an external linker (e.g. mold) has nothing to speed up here.
    // -Dllvm=false skips LLVM entirely and uses zig's self-hosted backend, which
    // cuts incremental rebuilds from ~7s to well under 1s. Combined with
    // ReleaseFast it still disables Debug's runtime safety checks, just without
    // LLVM's size/speed optimization passes — a middle ground for dev iteration.
    const use_llvm = b.option(bool, "llvm", "Use LLVM backend (default true); set -Dllvm=false for fast self-hosted dev builds") orelse true;

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("emojig", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
    });
    mod.link_libc = true;

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "emojig",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            // The self-hosted backend skips dead-code elimination and always
            // keeps debug info, so without LLVM the binary balloons to ~20MB;
            // stripping it (no LLVM/binutils needed) brings that down to ~6MB.
            // LLVM builds are unaffected: ReleaseSmall already auto-strips,
            // and ReleaseFast/Debug keep their prior (unstripped) behavior.
            .strip = if (use_llvm) null else true,
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "emojig" is the name you will use in your source code to
                // import this module (e.g. `@import("emojig")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "emojig", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    // Embed the declarative UI spec so the
    // binary is self-contained. `src/` is the module root, so @embedFile cannot
    // reach `../spec`; registering the files as anonymous imports makes them
    // available to @embedFile by import name from any file in this module.
    mod.addAnonymousImport("spec_layout", .{ .root_source_file = b.path("spec/layout.json") });
    mod.addAnonymousImport("spec_theme", .{ .root_source_file = b.path("spec/theme.json") });
    mod.addAnonymousImport("spec_keys", .{ .root_source_file = b.path("spec/keys.json") });
    mod.addAnonymousImport("spec_strings", .{ .root_source_file = b.path("spec/strings.json") });
    mod.addAnonymousImport("spec_commands", .{ .root_source_file = b.path("spec/commands.json") });
    mod.addAnonymousImport("spec_settings", .{ .root_source_file = b.path("spec/settings.json") });
    mod.addAnonymousImport("spec_categories", .{ .root_source_file = b.path("spec/categories.json") });
    mod.addAnonymousImport("spec_strings_es", .{ .root_source_file = b.path("spec/strings_es.json") });
    mod.addAnonymousImport("spec_strings_pt", .{ .root_source_file = b.path("spec/strings_pt.json") });
    mod.addAnonymousImport("spec_strings_fr", .{ .root_source_file = b.path("spec/strings_fr.json") });
    mod.addAnonymousImport("spec_strings_it", .{ .root_source_file = b.path("spec/strings_it.json") });
    mod.addAnonymousImport("spec_strings_de", .{ .root_source_file = b.path("spec/strings_de.json") });
    mod.addAnonymousImport("spec_strings_pl", .{ .root_source_file = b.path("spec/strings_pl.json") });
    mod.addAnonymousImport("spec_strings_ru", .{ .root_source_file = b.path("spec/strings_ru.json") });
    mod.addAnonymousImport("spec_strings_uk", .{ .root_source_file = b.path("spec/strings_uk.json") });
    mod.addAnonymousImport("spec_strings_nl", .{ .root_source_file = b.path("spec/strings_nl.json") });
    mod.addAnonymousImport("spec_strings_tr", .{ .root_source_file = b.path("spec/strings_tr.json") });
    mod.addAnonymousImport("spec_styles", .{ .root_source_file = b.path("spec/styles.json") });
    mod.addAnonymousImport("spec_colors", .{ .root_source_file = b.path("spec/colors.json") });

    exe.root_module.addAnonymousImport("spec_layout", .{ .root_source_file = b.path("spec/layout.json") });
    exe.root_module.addAnonymousImport("spec_theme", .{ .root_source_file = b.path("spec/theme.json") });
    exe.root_module.addAnonymousImport("spec_keys", .{ .root_source_file = b.path("spec/keys.json") });
    exe.root_module.addAnonymousImport("spec_strings", .{ .root_source_file = b.path("spec/strings.json") });
    exe.root_module.addAnonymousImport("spec_commands", .{ .root_source_file = b.path("spec/commands.json") });
    exe.root_module.addAnonymousImport("spec_settings", .{ .root_source_file = b.path("spec/settings.json") });
    exe.root_module.addAnonymousImport("spec_categories", .{ .root_source_file = b.path("spec/categories.json") });
    exe.root_module.addAnonymousImport("spec_strings_es", .{ .root_source_file = b.path("spec/strings_es.json") });
    exe.root_module.addAnonymousImport("spec_strings_pt", .{ .root_source_file = b.path("spec/strings_pt.json") });
    exe.root_module.addAnonymousImport("spec_strings_fr", .{ .root_source_file = b.path("spec/strings_fr.json") });
    exe.root_module.addAnonymousImport("spec_strings_it", .{ .root_source_file = b.path("spec/strings_it.json") });
    exe.root_module.addAnonymousImport("spec_strings_de", .{ .root_source_file = b.path("spec/strings_de.json") });
    exe.root_module.addAnonymousImport("spec_strings_pl", .{ .root_source_file = b.path("spec/strings_pl.json") });
    exe.root_module.addAnonymousImport("spec_strings_ru", .{ .root_source_file = b.path("spec/strings_ru.json") });
    exe.root_module.addAnonymousImport("spec_strings_uk", .{ .root_source_file = b.path("spec/strings_uk.json") });
    exe.root_module.addAnonymousImport("spec_strings_nl", .{ .root_source_file = b.path("spec/strings_nl.json") });
    exe.root_module.addAnonymousImport("spec_strings_tr", .{ .root_source_file = b.path("spec/strings_tr.json") });
    exe.root_module.addAnonymousImport("spec_styles", .{ .root_source_file = b.path("spec/styles.json") });
    exe.root_module.addAnonymousImport("spec_colors", .{ .root_source_file = b.path("spec/colors.json") });

    const version = b.option([]const u8, "version", "Version string (injected by GoReleaser)") orelse "dev";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", options);

    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Launch the emoji picker in a floating foot window.
    const picker_step = b.step("picker", "Launch the emoji picker in a floating foot window (non-blocking)");
    const run_picker = b.addRunArtifact(exe);
    run_picker.addArg("--gui");
    picker_step.dependOn(&run_picker.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const tui_step = b.step("tui", "Run TUI mode in the current terminal");
    const run_tui = b.addRunArtifact(exe);
    run_tui.addArg("--tui");
    tui_step.dependOn(&run_tui.step);

    const gui_step = b.step("gui", "Launch floating terminal window (--gui, requires foot)");
    const run_gui = b.addRunArtifact(exe);
    run_gui.addArg("--gui");
    gui_step.dependOn(&run_gui.step);

    // Named shell-install to avoid collision with Zig's built-in install step.
    const shell_install_step = b.step("shell-install", "Install shell integration scripts to ~/.local/share/emojig/shell/");
    const run_shell_install = b.addRunArtifact(exe);
    run_shell_install.addArg("--install");
    shell_install_step.dependOn(&run_shell_install.step);
}
