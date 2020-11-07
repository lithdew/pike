const std = @import("std");

const meta = std.meta;

pub fn UnionValueType(comptime Union: type, comptime Tag: anytype) type {
    return meta.fieldInfo(Union, @tagName(Tag)).field_type;
}