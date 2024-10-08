const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const override_colors = b.option(bool, "override-colors", "Override vertex colors") orelse false;
    
    const options = b.addOptions();
    options.addOption(bool, "override_colors", override_colors);

    const exe = b.addExecutable(.{
        .name = "matrisen",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addOptions("config", options);
    exe.linkLibCpp();
    exe.linkLibC();

    exe.linkSystemLibrary("SDL3");
    exe.linkSystemLibrary("lua5.4");
    exe.linkSystemLibrary("vulkan");

    exe.addCSourceFile(.{ .file = b.path("src/vk_mem_alloc.cpp"), .flags = &.{""} });
    exe.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = &.{""} });
    compile_all_shaders(b, exe);

    // artifacts
    // default
    b.installArtifact(exe);

    // run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // test
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.host,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn compile_all_shaders(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const shaders_dir = if (@hasDecl(@TypeOf(b.build_root.handle), "openIterableDir"))
        b.build_root.handle.openIterableDir("shaders", .{}) catch @panic("Failed to open shaders directory")
    else
        b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (!std.mem.eql(u8,ext,".glsl"))  {
                const basename = std.fs.path.basename(entry.name);
                const name = basename[0 .. basename.len - ext.len];
                std.debug.print("found shader file to compile: {s}. compiling with name: {s}\n", .{ entry.name, name });
                add_shader(b, exe, basename);
            }
        }
    }
}

fn add_shader(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8) void {
    const source = std.fmt.allocPrint(b.allocator, "shaders/{s}", .{name}) catch @panic("OOM");
    const outpath = std.fmt.allocPrint(b.allocator, "shaders/{s}.spv", .{name}) catch @panic("OOM");

    const shader_compilation = b.addSystemCommand(&.{"glslangValidator"});
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    const output = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addFileArg(b.path(source));

    exe.root_module.addAnonymousImport(name, .{ .root_source_file = output });
}
