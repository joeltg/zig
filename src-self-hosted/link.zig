const std = @import("std");
const c = @import("c.zig");
const builtin = @import("builtin");
const ObjectFormat = builtin.ObjectFormat;
const Compilation = @import("compilation.zig").Compilation;
const Target = @import("target.zig").Target;
const LibCInstallation = @import("libc_installation.zig").LibCInstallation;

const Context = struct {
    comp: *Compilation,
    arena: std.heap.ArenaAllocator,
    args: std.ArrayList([*]const u8),
    link_in_crt: bool,

    link_err: error{OutOfMemory}!void,
    link_msg: std.Buffer,

    libc: *LibCInstallation,
    out_file_path: std.Buffer,
};

pub async fn link(comp: *Compilation) !void {
    var ctx = Context{
        .comp = comp,
        .arena = std.heap.ArenaAllocator.init(comp.gpa()),
        .args = undefined,
        .link_in_crt = comp.haveLibC() and comp.kind == Compilation.Kind.Exe,
        .link_err = {},
        .link_msg = undefined,
        .libc = undefined,
        .out_file_path = undefined,
    };
    defer ctx.arena.deinit();
    ctx.args = std.ArrayList([*]const u8).init(&ctx.arena.allocator);
    ctx.link_msg = std.Buffer.initNull(&ctx.arena.allocator);

    if (comp.link_out_file) |out_file| {
        ctx.out_file_path = try std.Buffer.init(&ctx.arena.allocator, out_file);
    } else {
        ctx.out_file_path = try std.Buffer.init(&ctx.arena.allocator, comp.name.toSliceConst());
        switch (comp.kind) {
            Compilation.Kind.Exe => {
                try ctx.out_file_path.append(comp.target.exeFileExt());
            },
            Compilation.Kind.Lib => {
                try ctx.out_file_path.append(comp.target.libFileExt(comp.is_static));
            },
            Compilation.Kind.Obj => {
                try ctx.out_file_path.append(comp.target.objFileExt());
            },
        }
    }

    // even though we're calling LLD as a library it thinks the first
    // argument is its own exe name
    try ctx.args.append(c"lld");

    if (comp.haveLibC()) {
        ctx.libc = ctx.comp.override_libc orelse blk: {
            switch (comp.target) {
                Target.Native => {
                    break :blk (await (async comp.event_loop_local.getNativeLibC() catch unreachable)) catch return error.LibCRequiredButNotProvidedOrFound;
                },
                else => return error.LibCRequiredButNotProvidedOrFound,
            }
        };
    }

    try constructLinkerArgs(&ctx);

    if (comp.verbose_link) {
        for (ctx.args.toSliceConst()) |arg, i| {
            const space = if (i == 0) "" else " ";
            std.debug.warn("{}{s}", space, arg);
        }
        std.debug.warn("\n");
    }

    const extern_ofmt = toExternObjectFormatType(comp.target.getObjectFormat());
    const args_slice = ctx.args.toSlice();
    // Not evented I/O. LLD does its own multithreading internally.
    if (!ZigLLDLink(extern_ofmt, args_slice.ptr, args_slice.len, linkDiagCallback, @ptrCast(*c_void, &ctx))) {
        if (!ctx.link_msg.isNull()) {
            // TODO capture these messages and pass them through the system, reporting them through the
            // event system instead of printing them directly here.
            // perhaps try to parse and understand them.
            std.debug.warn("{}\n", ctx.link_msg.toSliceConst());
        }
        return error.LinkFailed;
    }
}

extern fn ZigLLDLink(
    oformat: c.ZigLLVM_ObjectFormatType,
    args: [*]const [*]const u8,
    arg_count: usize,
    append_diagnostic: extern fn (*c_void, [*]const u8, usize) void,
    context: *c_void,
) bool;

extern fn linkDiagCallback(context: *c_void, ptr: [*]const u8, len: usize) void {
    const ctx = @ptrCast(*Context, @alignCast(@alignOf(Context), context));
    ctx.link_err = linkDiagCallbackErrorable(ctx, ptr[0..len]);
}

fn linkDiagCallbackErrorable(ctx: *Context, msg: []const u8) !void {
    if (ctx.link_msg.isNull()) {
        try ctx.link_msg.resize(0);
    }
    try ctx.link_msg.append(msg);
}

fn toExternObjectFormatType(ofmt: ObjectFormat) c.ZigLLVM_ObjectFormatType {
    return switch (ofmt) {
        ObjectFormat.unknown => c.ZigLLVM_UnknownObjectFormat,
        ObjectFormat.coff => c.ZigLLVM_COFF,
        ObjectFormat.elf => c.ZigLLVM_ELF,
        ObjectFormat.macho => c.ZigLLVM_MachO,
        ObjectFormat.wasm => c.ZigLLVM_Wasm,
    };
}

fn constructLinkerArgs(ctx: *Context) !void {
    switch (ctx.comp.target.getObjectFormat()) {
        ObjectFormat.unknown => unreachable,
        ObjectFormat.coff => return constructLinkerArgsCoff(ctx),
        ObjectFormat.elf => return constructLinkerArgsElf(ctx),
        ObjectFormat.macho => return constructLinkerArgsMachO(ctx),
        ObjectFormat.wasm => return constructLinkerArgsWasm(ctx),
    }
}

fn constructLinkerArgsElf(ctx: *Context) !void {
    // TODO commented out code in this function
    //if (g->linker_script) {
    //    lj->args.append("-T");
    //    lj->args.append(g->linker_script);
    //}

    //if (g->no_rosegment_workaround) {
    //    lj->args.append("--no-rosegment");
    //}
    try ctx.args.append(c"--gc-sections");

    //lj->args.append("-m");
    //lj->args.append(getLDMOption(&g->zig_target));

    //bool is_lib = g->out_type == OutTypeLib;
    //bool shared = !g->is_static && is_lib;
    //Buf *soname = nullptr;
    if (ctx.comp.is_static) {
        if (ctx.comp.target.isArmOrThumb()) {
            try ctx.args.append(c"-Bstatic");
        } else {
            try ctx.args.append(c"-static");
        }
    }
    //} else if (shared) {
    //    lj->args.append("-shared");

    //    if (buf_len(&lj->out_file) == 0) {
    //        buf_appendf(&lj->out_file, "lib%s.so.%" ZIG_PRI_usize ".%" ZIG_PRI_usize ".%" ZIG_PRI_usize "",
    //                buf_ptr(g->root_out_name), g->version_major, g->version_minor, g->version_patch);
    //    }
    //    soname = buf_sprintf("lib%s.so.%" ZIG_PRI_usize "", buf_ptr(g->root_out_name), g->version_major);
    //}

    try ctx.args.append(c"-o");
    try ctx.args.append(ctx.out_file_path.ptr());

    if (ctx.link_in_crt) {
        const crt1o = if (ctx.comp.is_static) "crt1.o" else "Scrt1.o";
        const crtbegino = if (ctx.comp.is_static) "crtbeginT.o" else "crtbegin.o";
        try addPathJoin(ctx, ctx.libc.lib_dir.?, crt1o);
        try addPathJoin(ctx, ctx.libc.lib_dir.?, "crti.o");
        try addPathJoin(ctx, ctx.libc.static_lib_dir.?, crtbegino);
    }

    //for (size_t i = 0; i < g->rpath_list.length; i += 1) {
    //    Buf *rpath = g->rpath_list.at(i);
    //    add_rpath(lj, rpath);
    //}
    //if (g->each_lib_rpath) {
    //    for (size_t i = 0; i < g->lib_dirs.length; i += 1) {
    //        const char *lib_dir = g->lib_dirs.at(i);
    //        for (size_t i = 0; i < g->link_libs_list.length; i += 1) {
    //            LinkLib *link_lib = g->link_libs_list.at(i);
    //            if (buf_eql_str(link_lib->name, "c")) {
    //                continue;
    //            }
    //            bool does_exist;
    //            Buf *test_path = buf_sprintf("%s/lib%s.so", lib_dir, buf_ptr(link_lib->name));
    //            if (os_file_exists(test_path, &does_exist) != ErrorNone) {
    //                zig_panic("link: unable to check if file exists: %s", buf_ptr(test_path));
    //            }
    //            if (does_exist) {
    //                add_rpath(lj, buf_create_from_str(lib_dir));
    //                break;
    //            }
    //        }
    //    }
    //}

    //for (size_t i = 0; i < g->lib_dirs.length; i += 1) {
    //    const char *lib_dir = g->lib_dirs.at(i);
    //    lj->args.append("-L");
    //    lj->args.append(lib_dir);
    //}

    if (ctx.comp.haveLibC()) {
        try ctx.args.append(c"-L");
        try ctx.args.append((try std.cstr.addNullByte(&ctx.arena.allocator, ctx.libc.lib_dir.?)).ptr);

        try ctx.args.append(c"-L");
        try ctx.args.append((try std.cstr.addNullByte(&ctx.arena.allocator, ctx.libc.static_lib_dir.?)).ptr);

        if (!ctx.comp.is_static) {
            const dl = blk: {
                if (ctx.libc.dynamic_linker_path) |dl| break :blk dl;
                if (ctx.comp.target.getDynamicLinkerPath()) |dl| break :blk dl;
                return error.LibCMissingDynamicLinker;
            };
            try ctx.args.append(c"-dynamic-linker");
            try ctx.args.append((try std.cstr.addNullByte(&ctx.arena.allocator, dl)).ptr);
        }
    }

    //if (shared) {
    //    lj->args.append("-soname");
    //    lj->args.append(buf_ptr(soname));
    //}

    // .o files
    for (ctx.comp.link_objects) |link_object| {
        const link_obj_with_null = try std.cstr.addNullByte(&ctx.arena.allocator, link_object);
        try ctx.args.append(link_obj_with_null.ptr);
    }
    try addFnObjects(ctx);

    //if (g->out_type == OutTypeExe || g->out_type == OutTypeLib) {
    //    if (g->libc_link_lib == nullptr) {
    //        Buf *builtin_o_path = build_o(g, "builtin");
    //        lj->args.append(buf_ptr(builtin_o_path));
    //    }

    //    // sometimes libgcc is missing stuff, so we still build compiler_rt and rely on weak linkage
    //    Buf *compiler_rt_o_path = build_compiler_rt(g);
    //    lj->args.append(buf_ptr(compiler_rt_o_path));
    //}

    //for (size_t i = 0; i < g->link_libs_list.length; i += 1) {
    //    LinkLib *link_lib = g->link_libs_list.at(i);
    //    if (buf_eql_str(link_lib->name, "c")) {
    //        continue;
    //    }
    //    Buf *arg;
    //    if (buf_starts_with_str(link_lib->name, "/") || buf_ends_with_str(link_lib->name, ".a") ||
    //        buf_ends_with_str(link_lib->name, ".so"))
    //    {
    //        arg = link_lib->name;
    //    } else {
    //        arg = buf_sprintf("-l%s", buf_ptr(link_lib->name));
    //    }
    //    lj->args.append(buf_ptr(arg));
    //}

    // libc dep
    if (ctx.comp.haveLibC()) {
        if (ctx.comp.is_static) {
            try ctx.args.append(c"--start-group");
            try ctx.args.append(c"-lgcc");
            try ctx.args.append(c"-lgcc_eh");
            try ctx.args.append(c"-lc");
            try ctx.args.append(c"-lm");
            try ctx.args.append(c"--end-group");
        } else {
            try ctx.args.append(c"-lgcc");
            try ctx.args.append(c"--as-needed");
            try ctx.args.append(c"-lgcc_s");
            try ctx.args.append(c"--no-as-needed");
            try ctx.args.append(c"-lc");
            try ctx.args.append(c"-lm");
            try ctx.args.append(c"-lgcc");
            try ctx.args.append(c"--as-needed");
            try ctx.args.append(c"-lgcc_s");
            try ctx.args.append(c"--no-as-needed");
        }
    }

    // crt end
    if (ctx.link_in_crt) {
        try addPathJoin(ctx, ctx.libc.static_lib_dir.?, "crtend.o");
        try addPathJoin(ctx, ctx.libc.lib_dir.?, "crtn.o");
    }

    if (ctx.comp.target != Target.Native) {
        try ctx.args.append(c"--allow-shlib-undefined");
    }

    if (ctx.comp.target.getOs() == builtin.Os.zen) {
        try ctx.args.append(c"-e");
        try ctx.args.append(c"_start");

        try ctx.args.append(c"--image-base=0x10000000");
    }
}

fn addPathJoin(ctx: *Context, dirname: []const u8, basename: []const u8) !void {
    const full_path = try std.os.path.join(&ctx.arena.allocator, dirname, basename);
    const full_path_with_null = try std.cstr.addNullByte(&ctx.arena.allocator, full_path);
    try ctx.args.append(full_path_with_null.ptr);
}

fn constructLinkerArgsCoff(ctx: *Context) void {
    @panic("TODO");
}

fn constructLinkerArgsMachO(ctx: *Context) void {
    @panic("TODO");
}

fn constructLinkerArgsWasm(ctx: *Context) void {
    @panic("TODO");
}

fn addFnObjects(ctx: *Context) !void {
    // at this point it's guaranteed nobody else has this lock, so we circumvent it
    // and avoid having to be a coroutine
    const fn_link_set = &ctx.comp.fn_link_set.private_data;

    var it = fn_link_set.first;
    while (it) |node| {
        const fn_val = node.data orelse {
            // handle the tombstone. See Value.Fn.destroy.
            it = node.next;
            fn_link_set.remove(node);
            ctx.comp.gpa().destroy(node);
            continue;
        };
        try ctx.args.append(fn_val.containing_object.ptr());
        it = node.next;
    }
}
