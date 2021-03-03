const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn sliceCast(comptime Type: type, buffer: []u8, offset: usize, count: usize) []Type {
    return @ptrCast([*]Type, @alignCast(@alignOf(Type), buffer[offset..][0 .. @sizeOf(Type) * count]))[0..count];
}

fn find_symtab(section_headers: []std.elf.Elf64_Shdr) ?*const std.elf.Elf64_Shdr {
    for (section_headers) |*section| {
        if (section.sh_type == std.elf.SHT_SYMTAB)
            return section;
    }
    return null;
}

fn dummySpanZ(comptime Type: type, data: []Type) []Type {
    return data[0..std.mem.indexOf(u8, data, "\x00").?];
}

const SectionType = enum(u8) {
    Null = std.elf.SHT_NULL,
    //Progbits = std.elf.SHT_PROGBITS,
    Symtab = std.elf.SHT_SYMTAB,
    Strtab = std.elf.SHT_STRTAB,
    Rela = std.elf.SHT_RELA,
    //Hash = std.elf.SHT_HASH,
    //Dynamic = std.elf.SHT_DYNAMIC,
    Unknown,
};

const Symbol = extern struct {
    data: std.elf.Elf64_Sym,
};

const Section = struct {
    const Self = @This();
    header: *std.elf.Elf64_Shdr,
    name: ?[]u8,
    data: union(SectionType) {
        Null: void,
        Symtab: []std.elf.Elf64_Sym,
        Strtab: []u8,
        Rela: []std.elf.Elf64_Rela,
        Unknown,
    },

    pub fn getType(self: Self) SectionType {
        return std.meta.activeTag(self.data);
    }
};

const ObjectFile = struct {
    const Self = @This();
    allocator: *std.mem.Allocator,
    name: []u8,
    file: std.fs.File,
    header: *std.elf.Elf64_Ehdr,
    memory: []align(std.mem.page_size) u8,
    sections: ?std.ArrayListUnmanaged(Section) = null,

    pub fn init(self: *Self, allocator: *std.mem.Allocator, name: []u8) !void {
        self.allocator = allocator;
        self.name = name;
        var file = try std.fs.cwd().openFile(name, .{ .read = true });
        errdefer file.close();
        self.file = file;

        try file.seekFromEnd(0);
        const size = try file.getPos();
        try file.seekTo(0);

        const memory = try std.os.mmap(null, size, std.os.PROT_READ, std.os.MAP_PRIVATE, file.handle, 0);
        errdefer std.os.munmap(memory);
        self.memory = memory;

        const header: *std.elf.Elf64_Ehdr = @ptrCast(*std.elf.Elf64_Ehdr, memory[0..@sizeOf(std.elf.Elf64_Ehdr)]);
        if (!std.mem.eql(u8, header.e_ident[0..4], "\x7fELF")) return error.InvalidArgs;
        if (header.e_ident[std.elf.EI_VERSION] != 1) return error.InvalidArgs;

        const endian: std.builtin.Endian = switch (header.e_ident[std.elf.EI_DATA]) {
            std.elf.ELFDATA2LSB => .Little,
            std.elf.ELFDATA2MSB => .Big,
            else => return error.InvalidArgs,
        };

        // TODO: handle endianess different than native
        if (std.builtin.endian != endian) return error.InvalidArgs;
        self.header = header;

        //var program_headers = std.ArrayList(std.elf.Elf64_Phdr).init(allocator);
        //try program_headers.ensureCapacity(header.e_phnum);

        //var phdr_idx: usize = 0;
        //try file.seekTo(header.e_phoff);
        //while (phdr_idx < header.e_phnum) {
        //    phdr_idx += 1;
        //}
    }

    fn loadSections(self: *Self) !void {
        const section_headers = sliceCast(std.elf.Elf64_Shdr, self.memory, self.header.e_shoff, self.header.e_shnum);
        const section_header_strtab = section_headers[self.header.e_shstrndx];
        const section_header_strtab_data = self.memory[section_header_strtab.sh_offset..][0..section_header_strtab.sh_size];

        self.sections = try std.ArrayListUnmanaged(Section).initCapacity(self.allocator, self.header.e_shnum);
        for (section_headers) |*section| {
            self.sections.?.appendAssumeCapacity(Section{
                .header = section,
                .name = if (section.sh_name == 0) null else dummySpanZ(u8, section_header_strtab_data[section.sh_name..]),
                .data = switch (section.sh_type) {
                    std.elf.SHT_NULL => .Null,
                    //std.elf.SHT_PROGBITS => .Progbits,
                    std.elf.SHT_SYMTAB => .{ .Symtab = sliceCast(std.elf.Elf64_Sym, self.memory, section.sh_offset, section.sh_size / @sizeOf(std.elf.Elf64_Sym)) },
                    std.elf.SHT_STRTAB => .{ .Strtab = sliceCast(u8, self.memory, section.sh_offset, section.sh_size) },
                    std.elf.SHT_RELA => .{ .Rela = sliceCast(std.elf.Elf64_Rela, self.memory, section.sh_offset, section.sh_size / @sizeOf(std.elf.Elf64_Rela)) },
                    else => blk: {
                        std.log.warn("skipping unsupported section type: {}", .{section.sh_type});
                        break :blk .Unknown;
                    },
                },
            });
        }
    }

    pub fn loadSymbols(self: *Self) !void {
        //
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
        std.os.munmap(self.memory);
        self.sections.?.deinit(self.allocator);
        self.allocator.free(self.name);
    }
};

pub fn main() anyerror!void {
    defer _ = gpa.deinit();
    var allocator = &gpa.allocator;

    var object_files = std.ArrayList(ObjectFile).init(allocator);
    defer {
        for (object_files.items) |*obj| {
            obj.deinit();
        }
        object_files.deinit();
    }

    var arguments = std.process.args();
    _ = arguments.skip();
    while (arguments.next(allocator)) |arg| {
        var object = try object_files.addOne();
        try object.init(allocator, arg catch unreachable);
        try object.loadSections();
        try object.loadSymbols();

        for (object.sections.?.items) |*section| {
            switch (section.data) {
                .Symtab => |symbols| {
                    for (symbols) |sym| {
                        if (sym.st_name != 0) {
                            std.log.info("{} {s}", .{ sym, dummySpanZ(u8, object.sections.?.items[section.header.sh_link].data.Strtab[sym.st_name..]) });
                        }
                    }
                },
                .Rela => |relocations| {
                    for (relocations) |rel| {
                        //std.log.info("{}", .{rel});
                    }
                },
                else => {},
            }
        }
    }
}
