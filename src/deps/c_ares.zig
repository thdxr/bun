const c = @import("std").c;
const std = @import("std");
const bun = @import("bun");
const iovec = @import("std").os.iovec;
const struct_in_addr = std.os.sockaddr.in;
const struct_sockaddr = std.os.sockaddr;
pub const socklen_t = c.socklen_t;
const ares_socklen_t = c.socklen_t;
pub const ares_ssize_t = isize;
pub const ares_socket_t = c_int;
pub const ares_sock_state_cb = ?*const fn (?*anyopaque, ares_socket_t, c_int, c_int) callconv(.C) void;
pub const struct_apattern = opaque {};
const fd_set = c.fd_set;
pub const Options = extern struct {
    flags: c_int = 0,
    timeout: c_int = 0,
    tries: c_int = 0,
    ndots: c_int = 0,
    udp_port: c_ushort = 0,
    tcp_port: c_ushort = 0,
    socket_send_buffer_size: c_int = 0,
    socket_receive_buffer_size: c_int = 0,
    servers: [*c]struct_in_addr = null,
    nservers: c_int = 0,
    domains: [*c][*:0]u8 = null,
    ndomains: c_int = 0,
    lookups: [*c]u8 = null,
    sock_state_cb: ares_sock_state_cb = null,
    sock_state_cb_data: ?*anyopaque = null,
    sortlist: ?*struct_apattern = null,
    nsort: c_int = 0,
    ednspsz: c_int = 0,
    resolvconf_path: ?[*:0]u8 = null,
    hosts_path: ?[*:0]u8 = null,
};
pub const struct_hostent = opaque {};
pub const struct_timeval = opaque {};
pub const struct_Channeldata = opaque {};
pub const AddrInfo_cname = extern struct {
    ttl: c_int,
    alias: [*c]u8,
    name: [*c]u8,
    next: [*c]AddrInfo_cname,
};
pub const AddrInfo_node = extern struct {
    ttl: c_int = 0,
    flags: c_int = 0,
    family: c_int = 0,
    socktype: c_int = 0,
    protocol: c_int = 0,
    addrlen: ares_socklen_t,
    addr: ?*struct_sockaddr = null,
    next: ?*AddrInfo_node = null,

    pub fn count(this: *AddrInfo_node) u32 {
        var len: u32 = 0;
        var node: ?*AddrInfo_node = this;
        while (node != null) : (node = node.?.next) {
            len += 1;
        }
        return len;
    }
};
pub const AddrInfo = extern struct {
    cnames_: [*c]AddrInfo_cname = null,
    node: ?*AddrInfo_node = null,
    name_: ?[*:0]u8 = null,

    const JSC = bun.JSC;

    pub fn toJSArray(
        addr_info: *AddrInfo,
        parent_allocator: std.mem.Allocator,
        globalThis: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        var stack = std.heap.stackFallback(2048, parent_allocator);
        var arena = std.heap.ArenaAllocator.init(stack.get());
        var node = addr_info.node.?;
        const array = JSC.JSValue.createEmptyArray(
            globalThis,
            node.count(),
        );

        {
            defer arena.deinit();

            var allocator = arena.allocator();
            var j: u32 = 0;
            var current: ?*AddrInfo_node = addr_info.node;
            while (current) |this_node| : (current = this_node.next) {
                array.putIndex(
                    globalThis,
                    j,
                    bun.JSC.DNS.GetAddrInfo.Result.toJS(
                        &.{
                            .address = switch (this_node.family) {
                                std.os.AF.INET => std.net.Address{ .in = .{ .sa = bun.cast(*const std.os.sockaddr.in, this_node.addr.?).* } },
                                std.os.AF.INET6 => std.net.Address{ .in6 = .{ .sa = bun.cast(*const std.os.sockaddr.in6, this_node.addr.?).* } },
                                else => unreachable,
                            },
                            .ttl = this_node.ttl,
                        },
                        globalThis,
                        allocator,
                    ),
                );
                j += 1;
            }
        }

        return array;
    }

    pub inline fn name(this: *const AddrInfo) []const u8 {
        var name_ = this.name_ orelse return "";
        return bun.span(name_);
    }

    pub inline fn cnames(this: *const AddrInfo) []const AddrInfo_node {
        var cnames_ = this.cnames_ orelse return &.{};
        return bun.span(cnames_);
    }

    pub fn Callback(comptime Type: type) type {
        return fn (*Type, status: ?Error, timeouts: i32, results: ?*AddrInfo) void;
    }

    pub fn callbackWrapper(
        comptime Type: type,
        comptime function: Callback(Type),
    ) ares_addrinfo_callback {
        return &struct {
            pub fn handleAddrInfo(ctx: ?*anyopaque, status: c_int, timeouts: c_int, addr_info: ?*AddrInfo) callconv(.C) void {
                var this = bun.cast(*Type, ctx.?);

                function(this, Error.get(status), timeouts, addr_info);
            }
        }.handleAddrInfo;
    }

    pub fn deinit(this: *AddrInfo) void {
        ares_freeaddrinfo(this);
    }
};
pub const AddrInfo_hints = extern struct {
    ai_flags: c_int = 0,
    ai_family: c_int = 0,
    ai_socktype: c_int = 0,
    ai_protocol: c_int = 0,

    pub fn isEmpty(this: AddrInfo_hints) bool {
        return this.ai_flags == 0 and this.ai_family == 0 and this.ai_socktype == 0 and this.ai_protocol == 0;
    }
};
pub const Channel = opaque {
    pub fn init(comptime Container: type, this: *Container) ?Error {
        var channel: *Channel = undefined;

        libraryInit();

        if (Error.get(ares_init(&channel))) |err| {
            return err;
        }
        const SockStateWrap = struct {
            pub fn onSockState(ctx: ?*anyopaque, socket: ares_socket_t, readable: c_int, writable: c_int) callconv(.C) void {
                var container = bun.cast(*Container, ctx.?);
                Container.onDNSSocketState(container, @intCast(i32, socket), readable != 0, writable != 0);
            }
        };

        var opts = bun.zero(Options);

        opts.flags = ARES_FLAG_NOCHECKRESP;
        opts.sock_state_cb = &SockStateWrap.onSockState;
        opts.sock_state_cb_data = @ptrCast(*anyopaque, this);
        opts.timeout = 1000;
        opts.tries = 3;

        const optmask: c_int =
            ARES_OPT_FLAGS | ARES_OPT_TIMEOUTMS |
            ARES_OPT_SOCK_STATE_CB | ARES_OPT_TRIES;

        if (Error.get(ares_init_options(&channel, &opts, optmask))) |err| {
            ares_library_cleanup();
            return err;
        }

        this.channel = channel;
        return null;
    }

    ///
    ///The ares_getaddrinfo function initiates a host query by name on the name service channel identified by channel. The name and service parameters give the hostname and service as NULL-terminated C strings. The hints parameter is an ares_addrinfo_hints structure:
    ///
    ///struct ares_addrinfo_hints {   int ai_flags;   int ai_family;   int ai_socktype;   int ai_protocol; };
    ///
    ///ai_family Specifies desired address family. AF_UNSPEC means return both AF_INET and AF_INET6.
    ///
    ///ai_socktype Specifies desired socket type, for example SOCK_STREAM or SOCK_DGRAM. Setting this to 0 means any type.
    ///
    ///ai_protocol Setting this to 0 means any protocol.
    ///
    ///ai_flags Specifies additional options, see below.
    ///
    ///ARES_AI_NUMERICSERV If this option is set service field will be treated as a numeric value.
    ///
    ///ARES_AI_CANONNAME The ares_addrinfo structure will return a canonical names list.
    ///
    ///ARES_AI_NOSORT Result addresses will not be sorted and no connections to resolved addresses will be attempted.
    ///
    ///ARES_AI_ENVHOSTS Read hosts file path from the environment variable CARES_HOSTS .
    ///
    ///When the query is complete or has failed, the ares library will invoke callback. Completion or failure of the query may happen immediately, or may happen during a later call to ares_process, ares_destroy or ares_cancel.
    ///
    ///The callback argument arg is copied from the ares_getaddrinfo argument arg. The callback argument status indicates whether the query succeeded and, if not, how it failed. It may have any of the following values:
    ///
    ///ARES_SUCCESS The host lookup completed successfully.
    ///
    ///ARES_ENOTIMP The ares library does not know how to find addresses of type family.
    ///
    ///ARES_ENOTFOUND The name was not found.
    ///
    ///ARES_ENOMEM Memory was exhausted.
    ///
    ///ARES_ECANCELLED The query was cancelled.
    ///
    ///ARES_EDESTRUCTION The name service channel channel is being destroyed; the query will not be completed.
    ///
    ///On successful completion of the query, the callback argument result points to a struct ares_addrinfo which contains two linked lists, one with resolved addresses and another with canonical names. Also included is the official name of the host (analogous to gethostbyname() h_name).
    ///
    ///struct ares_addrinfo {   struct ares_addrinfo_cname *cnames;   struct ares_addrinfo_node *nodes;   char *name; };
    ///
    ///ares_addrinfo_node structure is similar to RFC 3493 addrinfo, but without canonname and with extra ttl field.
    ///
    ///struct ares_addrinfo_node {   int ai_ttl;   int ai_flags;   int ai_family;   int ai_socktype;   int ai_protocol;   ares_socklen_t ai_addrlen;   struct sockaddr *ai_addr;   struct ares_addrinfo_node *ai_next; };
    ///
    ///ares_addrinfo_cname structure is a linked list of CNAME records where ttl is a time to live alias is a label of the resource record and name is a value (canonical name) of the resource record. See RFC 2181 10.1.1. CNAME terminology.
    ///
    ///struct ares_addrinfo_cname {   int ttl;   char *alias;   char *name;   struct ares_addrinfo_cname *next; };
    ///
    ///The reserved memory has to be deleted by ares_freeaddrinfo.
    ///
    ///The result is sorted according to RFC 6724 except:  - Rule 3 (Avoid deprecated addresses)  - Rule 4 (Prefer home addresses)  - Rule 7 (Prefer native transport)
    ///
    ///Please note that the function will attempt a connection on each of the resolved addresses as per RFC 6724.
    ///
    pub fn getAddrInfo(this: *Channel, host: []const u8, port: u16, hints: []const AddrInfo_hints, comptime Type: type, ctx: *Type, comptime callback: AddrInfo.Callback(Type)) void {
        var host_buf: [1024]u8 = undefined;
        var port_buf: [52]u8 = undefined;
        const host_ptr: ?[*:0]const u8 = brk: {
            if (!(host.len > 0 and !bun.strings.eqlComptime(host, "0.0.0.0") and !bun.strings.eqlComptime(host, "::0"))) {
                break :brk null;
            }
            const len = @min(host.len, host_buf.len - 1);
            @memcpy(&host_buf, host.ptr, len);
            host_buf[len] = 0;
            break :brk host_buf[0..len :0].ptr;
        };

        const port_ptr: ?[*:0]const u8 = brk: {
            if (port == 0) {
                break :brk null;
            }

            break :brk (std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch unreachable).ptr;
        };

        var hints_buf: [3]AddrInfo_hints = bun.zero([3]AddrInfo_hints);
        for (hints[0..@min(hints.len, 2)]) |hint, i| {
            hints_buf[i] = hint;
        }
        var hints_: [*c]const AddrInfo_hints = if (hints.len > 0) &hints_buf else null;
        ares_getaddrinfo(this, host_ptr, port_ptr, hints_, AddrInfo.callbackWrapper(Type, callback), ctx);
    }

    pub inline fn process(this: *Channel, fd: i32, readable: bool, writable: bool) void {
        ares_process_fd(
            this,
            if (readable) fd else ARES_SOCKET_BAD,
            if (writable) fd else ARES_SOCKET_BAD,
        );
    }
};

var ares_has_loaded = std.atomic.Atomic(bool).init(false);
fn libraryInit() void {
    if (ares_has_loaded.swap(true, .Monotonic))
        return;

    const rc = ares_library_init_mem(
        ARES_LIB_INIT_ALL,
        bun.Mimalloc.mi_malloc,
        bun.Mimalloc.mi_free,
        bun.Mimalloc.mi_realloc,
    );
    if (rc != ARES_SUCCESS) {
        std.debug.panic("ares_library_init_mem failed: {any}", .{rc});
        unreachable;
    }
}

pub const ares_callback = ?*const fn (?*anyopaque, c_int, c_int, [*c]u8, c_int) callconv(.C) void;
pub const ares_host_callback = ?*const fn (?*anyopaque, c_int, c_int, ?*struct_hostent) callconv(.C) void;
pub const ares_nameinfo_callback = ?*const fn (?*anyopaque, c_int, c_int, [*c]u8, [*c]u8) callconv(.C) void;
pub const ares_sock_create_callback = ?*const fn (ares_socket_t, c_int, ?*anyopaque) callconv(.C) c_int;
pub const ares_sock_config_callback = ?*const fn (ares_socket_t, c_int, ?*anyopaque) callconv(.C) c_int;
pub const ares_addrinfo_callback = *const fn (?*anyopaque, c_int, c_int, ?*AddrInfo) callconv(.C) void;
pub extern fn ares_library_init(flags: c_int) c_int;
pub extern fn ares_library_init_mem(flags: c_int, amalloc: ?*const fn (usize) callconv(.C) ?*anyopaque, afree: ?*const fn (?*anyopaque) callconv(.C) void, arealloc: ?*const fn (?*anyopaque, usize) callconv(.C) ?*anyopaque) c_int;
pub extern fn ares_library_initialized() c_int;
pub extern fn ares_library_cleanup() void;
pub extern fn ares_version(version: [*c]c_int) [*c]const u8;
pub extern fn ares_init(channelptr: **Channel) c_int;
pub extern fn ares_init_options(channelptr: **Channel, options: ?*Options, optmask: c_int) c_int;
pub extern fn ares_save_options(channel: *Channel, options: ?*Options, optmask: *c_int) c_int;
pub extern fn ares_destroy_options(options: *Options) void;
pub extern fn ares_dup(dest: ?*Channel, src: *Channel) c_int;
pub extern fn ares_destroy(channel: *Channel) void;
pub extern fn ares_cancel(channel: *Channel) void;
pub extern fn ares_set_local_ip4(channel: *Channel, local_ip: c_uint) void;
pub extern fn ares_set_local_ip6(channel: *Channel, local_ip6: [*c]const u8) void;
pub extern fn ares_set_local_dev(channel: *Channel, local_dev_name: [*c]const u8) void;
pub extern fn ares_set_socket_callback(channel: *Channel, callback: ares_sock_create_callback, user_data: ?*anyopaque) void;
pub extern fn ares_set_socket_configure_callback(channel: *Channel, callback: ares_sock_config_callback, user_data: ?*anyopaque) void;
pub extern fn ares_set_sortlist(channel: *Channel, sortstr: [*c]const u8) c_int;
pub extern fn ares_getaddrinfo(channel: *Channel, node: ?[*:0]const u8, service: ?[*:0]const u8, hints: [*c]const AddrInfo_hints, callback: ares_addrinfo_callback, arg: ?*anyopaque) void;
pub extern fn ares_freeaddrinfo(ai: *AddrInfo) void;
pub const ares_socket_functions = extern struct {
    socket: ?*const fn (c_int, c_int, c_int, ?*anyopaque) callconv(.C) ares_socket_t = null,
    close: ?*const fn (ares_socket_t, ?*anyopaque) callconv(.C) c_int = null,
    connect: ?*const fn (ares_socket_t, [*c]const struct_sockaddr, ares_socklen_t, ?*anyopaque) callconv(.C) c_int = null,
    recvfrom: ?*const fn (ares_socket_t, ?*anyopaque, usize, c_int, [*c]struct_sockaddr, [*c]ares_socklen_t, ?*anyopaque) callconv(.C) ares_ssize_t = null,
    sendv: ?*const fn (ares_socket_t, [*c]const iovec, c_int, ?*anyopaque) callconv(.C) ares_ssize_t = null,
};
pub extern fn ares_set_socket_functions(channel: *Channel, funcs: ?*const ares_socket_functions, user_data: ?*anyopaque) void;
pub extern fn ares_send(channel: *Channel, qbuf: [*c]const u8, qlen: c_int, callback: ares_callback, arg: ?*anyopaque) void;
pub extern fn ares_query(channel: *Channel, name: [*c]const u8, dnsclass: c_int, @"type": c_int, callback: ares_callback, arg: ?*anyopaque) void;
pub extern fn ares_search(channel: *Channel, name: [*c]const u8, dnsclass: c_int, @"type": c_int, callback: ares_callback, arg: ?*anyopaque) void;
pub extern fn ares_gethostbyname(channel: *Channel, name: [*c]const u8, family: c_int, callback: ares_host_callback, arg: ?*anyopaque) void;
pub extern fn ares_gethostbyname_file(channel: *Channel, name: [*c]const u8, family: c_int, host: [*:null]?*struct_hostent) c_int;
pub extern fn ares_gethostbyaddr(channel: *Channel, addr: ?*const anyopaque, addrlen: c_int, family: c_int, callback: ares_host_callback, arg: ?*anyopaque) void;
pub extern fn ares_getnameinfo(channel: *Channel, sa: [*c]const struct_sockaddr, salen: ares_socklen_t, flags: c_int, callback: ares_nameinfo_callback, arg: ?*anyopaque) void;
// pub extern fn ares_fds(channel: *Channel, read_fds: *fd_set, write_fds: *fd_set) c_int;
pub extern fn ares_getsock(channel: *Channel, socks: [*c]ares_socket_t, numsocks: c_int) c_int;
pub extern fn ares_timeout(channel: *Channel, maxtv: ?*struct_timeval, tv: ?*struct_timeval) ?*struct_timeval;
// pub extern fn ares_process(channel: *Channel, read_fds: *fd_set, write_fds: *fd_set) void;
pub extern fn ares_process_fd(channel: *Channel, read_fd: ares_socket_t, write_fd: ares_socket_t) void;
pub extern fn ares_create_query(name: [*c]const u8, dnsclass: c_int, @"type": c_int, id: c_ushort, rd: c_int, buf: [*c][*c]u8, buflen: [*c]c_int, max_udp_size: c_int) c_int;
pub extern fn ares_mkquery(name: [*c]const u8, dnsclass: c_int, @"type": c_int, id: c_ushort, rd: c_int, buf: [*c][*c]u8, buflen: [*c]c_int) c_int;
pub extern fn ares_expand_name(encoded: [*c]const u8, abuf: [*c]const u8, alen: c_int, s: [*c][*c]u8, enclen: [*c]c_long) c_int;
pub extern fn ares_expand_string(encoded: [*c]const u8, abuf: [*c]const u8, alen: c_int, s: [*c][*c]u8, enclen: [*c]c_long) c_int;
const union_unnamed_2 = extern union {
    _S6_u8: [16]u8,
};
pub const struct_ares_in6_addr = extern struct {
    _S6_un: union_unnamed_2,
};
pub const struct_ares_addrttl = extern struct {
    ipaddr: struct_in_addr,
    ttl: c_int,
};
pub const struct_ares_addr6ttl = extern struct {
    ip6addr: struct_ares_in6_addr,
    ttl: c_int,
};
pub const struct_ares_caa_reply = extern struct {
    next: [*c]struct_ares_caa_reply,
    critical: c_int,
    property: [*c]u8,
    plength: usize,
    value: [*c]u8,
    length: usize,
};
pub const struct_ares_srv_reply = extern struct {
    next: [*c]struct_ares_srv_reply,
    host: [*c]u8,
    priority: c_ushort,
    weight: c_ushort,
    port: c_ushort,
};
pub const struct_ares_mx_reply = extern struct {
    next: [*c]struct_ares_mx_reply,
    host: [*c]u8,
    priority: c_ushort,
};
pub const struct_ares_txt_reply = extern struct {
    next: [*c]struct_ares_txt_reply,
    txt: [*c]u8,
    length: usize,
};
pub const struct_ares_txt_ext = extern struct {
    next: [*c]struct_ares_txt_ext,
    txt: [*c]u8,
    length: usize,
    record_start: u8,
};
pub const struct_ares_naptr_reply = extern struct {
    next: [*c]struct_ares_naptr_reply,
    flags: [*c]u8,
    service: [*c]u8,
    regexp: [*c]u8,
    replacement: [*c]u8,
    order: c_ushort,
    preference: c_ushort,
};
pub const struct_ares_soa_reply = extern struct {
    nsname: [*c]u8,
    hostmaster: [*c]u8,
    serial: c_uint,
    refresh: c_uint,
    retry: c_uint,
    expire: c_uint,
    minttl: c_uint,
};
pub const struct_ares_uri_reply = extern struct {
    next: [*c]struct_ares_uri_reply,
    priority: c_ushort,
    weight: c_ushort,
    uri: [*c]u8,
    ttl: c_int,
};
pub extern fn ares_parse_a_reply(abuf: [*c]const u8, alen: c_int, host: [*c]?*struct_hostent, addrttls: [*c]struct_ares_addrttl, naddrttls: [*c]c_int) c_int;
pub extern fn ares_parse_aaaa_reply(abuf: [*c]const u8, alen: c_int, host: [*c]?*struct_hostent, addrttls: [*c]struct_ares_addr6ttl, naddrttls: [*c]c_int) c_int;
pub extern fn ares_parse_caa_reply(abuf: [*c]const u8, alen: c_int, caa_out: [*c][*c]struct_ares_caa_reply) c_int;
pub extern fn ares_parse_ptr_reply(abuf: [*c]const u8, alen: c_int, addr: ?*const anyopaque, addrlen: c_int, family: c_int, host: [*c]?*struct_hostent) c_int;
pub extern fn ares_parse_ns_reply(abuf: [*c]const u8, alen: c_int, host: [*c]?*struct_hostent) c_int;
pub extern fn ares_parse_srv_reply(abuf: [*c]const u8, alen: c_int, srv_out: [*c][*c]struct_ares_srv_reply) c_int;
pub extern fn ares_parse_mx_reply(abuf: [*c]const u8, alen: c_int, mx_out: [*c][*c]struct_ares_mx_reply) c_int;
pub extern fn ares_parse_txt_reply(abuf: [*c]const u8, alen: c_int, txt_out: [*c][*c]struct_ares_txt_reply) c_int;
pub extern fn ares_parse_txt_reply_ext(abuf: [*c]const u8, alen: c_int, txt_out: [*c][*c]struct_ares_txt_ext) c_int;
pub extern fn ares_parse_naptr_reply(abuf: [*c]const u8, alen: c_int, naptr_out: [*c][*c]struct_ares_naptr_reply) c_int;
pub extern fn ares_parse_soa_reply(abuf: [*c]const u8, alen: c_int, soa_out: [*c][*c]struct_ares_soa_reply) c_int;
pub extern fn ares_parse_uri_reply(abuf: [*c]const u8, alen: c_int, uri_out: [*c][*c]struct_ares_uri_reply) c_int;
pub extern fn ares_free_string(str: ?*anyopaque) void;
pub extern fn ares_free_hostent(host: ?*struct_hostent) void;
pub extern fn ares_free_data(dataptr: ?*anyopaque) void;
pub extern fn ares_strerror(code: c_int) [*c]const u8;
const union_unnamed_3 = extern union {
    addr4: struct_in_addr,
    addr6: struct_ares_in6_addr,
};
pub const struct_ares_addr_node = extern struct {
    next: [*c]struct_ares_addr_node,
    family: c_int,
    addr: union_unnamed_3,
};
const union_unnamed_4 = extern union {
    addr4: struct_in_addr,
    addr6: struct_ares_in6_addr,
};
pub const struct_ares_addr_port_node = extern struct {
    next: [*c]struct_ares_addr_port_node,
    family: c_int,
    addr: union_unnamed_4,
    udp_port: c_int,
    tcp_port: c_int,
};
pub extern fn ares_set_servers(channel: *Channel, servers: [*c]struct_ares_addr_node) c_int;
pub extern fn ares_set_servers_ports(channel: *Channel, servers: [*c]struct_ares_addr_port_node) c_int;
pub extern fn ares_set_servers_csv(channel: *Channel, servers: [*c]const u8) c_int;
pub extern fn ares_set_servers_ports_csv(channel: *Channel, servers: [*c]const u8) c_int;
pub extern fn ares_get_servers(channel: *Channel, servers: [*c][*c]struct_ares_addr_node) c_int;
pub extern fn ares_get_servers_ports(channel: *Channel, servers: [*c][*c]struct_ares_addr_port_node) c_int;
pub extern fn ares_inet_ntop(af: c_int, src: ?*const anyopaque, dst: [*c]u8, size: ares_socklen_t) [*c]const u8;
pub extern fn ares_inet_pton(af: c_int, src: [*c]const u8, dst: ?*anyopaque) c_int;
pub const ARES_SUCCESS = 0;
pub const ARES_ENODATA = 1;
pub const ARES_EFORMERR = 2;
pub const ARES_ESERVFAIL = 3;
pub const ARES_ENOTFOUND = 4;
pub const ARES_ENOTIMP = 5;
pub const ARES_EREFUSED = 6;
pub const ARES_EBADQUERY = 7;
pub const ARES_EBADNAME = 8;
pub const ARES_EBADFAMILY = 9;
pub const ARES_EBADRESP = 10;
pub const ARES_ECONNREFUSED = 11;
pub const ARES_ETIMEOUT = 12;
pub const ARES_EOF = 13;
pub const ARES_EFILE = 14;
pub const ARES_ENOMEM = 15;
pub const ARES_EDESTRUCTION = 16;
pub const ARES_EBADSTR = 17;
pub const ARES_EBADFLAGS = 18;
pub const ARES_ENONAME = 19;
pub const ARES_EBADHINTS = 20;
pub const ARES_ENOTINITIALIZED = 21;
pub const ARES_ELOADIPHLPAPI = 22;
pub const ARES_EADDRGETNETWORKPARAMS = 23;
pub const ARES_ECANCELLED = 24;
pub const ARES_ESERVICE = 25;

pub const Error = enum(i32) {
    ENODATA = ARES_ENODATA,
    EFORMERR = ARES_EFORMERR,
    ESERVFAIL = ARES_ESERVFAIL,
    ENOTFOUND = ARES_ENOTFOUND,
    ENOTIMP = ARES_ENOTIMP,
    EREFUSED = ARES_EREFUSED,
    EBADQUERY = ARES_EBADQUERY,
    EBADNAME = ARES_EBADNAME,
    EBADFAMILY = ARES_EBADFAMILY,
    EBADRESP = ARES_EBADRESP,
    ECONNREFUSED = ARES_ECONNREFUSED,
    ETIMEOUT = ARES_ETIMEOUT,
    EOF = ARES_EOF,
    EFILE = ARES_EFILE,
    ENOMEM = ARES_ENOMEM,
    EDESTRUCTION = ARES_EDESTRUCTION,
    EBADSTR = ARES_EBADSTR,
    EBADFLAGS = ARES_EBADFLAGS,
    ENONAME = ARES_ENONAME,
    EBADHINTS = ARES_EBADHINTS,
    ENOTINITIALIZED = ARES_ENOTINITIALIZED,
    ELOADIPHLPAPI = ARES_ELOADIPHLPAPI,
    EADDRGETNETWORKPARAMS = ARES_EADDRGETNETWORKPARAMS,
    ECANCELLED = ARES_ECANCELLED,
    ESERVICE = ARES_ESERVICE,

    pub fn initEAI(rc: i32) ?Error {
        return switch (@intToEnum(std.os.system.EAI, rc)) {
            @intToEnum(std.os.system.EAI, 0) => return null,
            .ADDRFAMILY => Error.EBADFAMILY,
            .BADFLAGS => Error.EBADFLAGS, // Invalid hints
            .FAIL => Error.EBADRESP,
            .FAMILY => Error.EBADFAMILY,
            .MEMORY => Error.ENOMEM,
            .NODATA => Error.ENODATA,
            .NONAME => Error.ENONAME,
            .SERVICE => Error.ESERVICE,
            .SYSTEM => Error.ESERVFAIL,
            else => unreachable,
        };
    }

    pub const code = bun.enumMap(Error, .{
        .{ .ENODATA, "DNS_ENODATA" },
        .{ .EFORMERR, "DNS_EFORMERR" },
        .{ .ESERVFAIL, "DNS_ESERVFAIL" },
        .{ .ENOTFOUND, "DNS_ENOTFOUND" },
        .{ .ENOTIMP, "DNS_ENOTIMP" },
        .{ .EREFUSED, "DNS_EREFUSED" },
        .{ .EBADQUERY, "DNS_EBADQUERY" },
        .{ .EBADNAME, "DNS_EBADNAME" },
        .{ .EBADFAMILY, "DNS_EBADFAMILY" },
        .{ .EBADRESP, "DNS_EBADRESP" },
        .{ .ECONNREFUSED, "DNS_ECONNREFUSED" },
        .{ .ETIMEOUT, "DNS_ETIMEOUT" },
        .{ .EOF, "DNS_EOF" },
        .{ .EFILE, "DNS_EFILE" },
        .{ .ENOMEM, "DNS_ENOMEM" },
        .{ .EDESTRUCTION, "DNS_EDESTRUCTION" },
        .{ .EBADSTR, "DNS_EBADSTR" },
        .{ .EBADFLAGS, "DNS_EBADFLAGS" },
        .{ .ENONAME, "DNS_ENONAME" },
        .{ .EBADHINTS, "DNS_EBADHINTS" },
        .{ .ENOTINITIALIZED, "DNS_ENOTINITIALIZED" },
        .{ .ELOADIPHLPAPI, "DNS_ELOADIPHLPAPI" },
        .{ .EADDRGETNETWORKPARAMS, "DNS_EADDRGETNETWORKPARAMS" },
        .{ .ECANCELLED, "DNS_ECANCELLED" },
        .{ .ESERVICE, "DNS_ESERVICE" },
    });

    pub const label = bun.enumMap(Error, .{
        .{ .ENODATA, "No data record of requested type" },
        .{ .EFORMERR, "Malformed DNS query" },
        .{ .ESERVFAIL, "Server failed to complete the DNS operation" },
        .{ .ENOTFOUND, "Domain name not found" },
        .{ .ENOTIMP, "DNS resolver does not implement requested operation" },
        .{ .EREFUSED, "DNS operation refused" },
        .{ .EBADQUERY, "Misformatted DNS query" },
        .{ .EBADNAME, "Misformatted domain name" },
        .{ .EBADFAMILY, "Misformatted DNS query (family)" },
        .{ .EBADRESP, "Misformatted DNS reply" },
        .{ .ECONNREFUSED, "Could not contact DNS servers" },
        .{ .ETIMEOUT, "Timeout while contacting DNS servers" },
        .{ .EOF, "End of file" },
        .{ .EFILE, "Error reading file" },
        .{ .ENOMEM, "Out of memory" },
        .{ .EDESTRUCTION, "Channel is being destroyed" },
        .{ .EBADSTR, "Misformatted string" },
        .{ .EBADFLAGS, "Illegal flags specified" },
        .{ .ENONAME, "Given hostname is not numeric" },
        .{ .EBADHINTS, "Illegal hints flags specified" },
        .{ .ENOTINITIALIZED, "Library initialization not yet performed" },
        .{ .ELOADIPHLPAPI, "ELOADIPHLPAPI TODO WHAT DOES THIS MEAN" },
        .{ .EADDRGETNETWORKPARAMS, "EADDRGETNETWORKPARAMS" },
        .{ .ECANCELLED, "DNS query cancelled" },
        .{ .ESERVICE, "Service not available" },
    });

    pub fn get(rc: i32) ?Error {
        return switch (rc) {
            0 => null,
            1...ARES_ESERVICE => @intToEnum(Error, rc),
            -ARES_ESERVICE...-1 => @intToEnum(Error, -rc),
            else => unreachable,
        };
    }
};

pub const ARES_FLAG_USEVC = @as(c_int, 1) << @as(c_int, 0);
pub const ARES_FLAG_PRIMARY = @as(c_int, 1) << @as(c_int, 1);
pub const ARES_FLAG_IGNTC = @as(c_int, 1) << @as(c_int, 2);
pub const ARES_FLAG_NORECURSE = @as(c_int, 1) << @as(c_int, 3);
pub const ARES_FLAG_STAYOPEN = @as(c_int, 1) << @as(c_int, 4);
pub const ARES_FLAG_NOSEARCH = @as(c_int, 1) << @as(c_int, 5);
pub const ARES_FLAG_NOALIASES = @as(c_int, 1) << @as(c_int, 6);
pub const ARES_FLAG_NOCHECKRESP = @as(c_int, 1) << @as(c_int, 7);
pub const ARES_FLAG_EDNS = @as(c_int, 1) << @as(c_int, 8);
pub const ARES_OPT_FLAGS = @as(c_int, 1) << @as(c_int, 0);
pub const ARES_OPT_TIMEOUT = @as(c_int, 1) << @as(c_int, 1);
pub const ARES_OPT_TRIES = @as(c_int, 1) << @as(c_int, 2);
pub const ARES_OPT_NDOTS = @as(c_int, 1) << @as(c_int, 3);
pub const ARES_OPT_UDP_PORT = @as(c_int, 1) << @as(c_int, 4);
pub const ARES_OPT_TCP_PORT = @as(c_int, 1) << @as(c_int, 5);
pub const ARES_OPT_SERVERS = @as(c_int, 1) << @as(c_int, 6);
pub const ARES_OPT_DOMAINS = @as(c_int, 1) << @as(c_int, 7);
pub const ARES_OPT_LOOKUPS = @as(c_int, 1) << @as(c_int, 8);
pub const ARES_OPT_SOCK_STATE_CB = @as(c_int, 1) << @as(c_int, 9);
pub const ARES_OPT_SORTLIST = @as(c_int, 1) << @as(c_int, 10);
pub const ARES_OPT_SOCK_SNDBUF = @as(c_int, 1) << @as(c_int, 11);
pub const ARES_OPT_SOCK_RCVBUF = @as(c_int, 1) << @as(c_int, 12);
pub const ARES_OPT_TIMEOUTMS = @as(c_int, 1) << @as(c_int, 13);
pub const ARES_OPT_ROTATE = @as(c_int, 1) << @as(c_int, 14);
pub const ARES_OPT_EDNSPSZ = @as(c_int, 1) << @as(c_int, 15);
pub const ARES_OPT_NOROTATE = @as(c_int, 1) << @as(c_int, 16);
pub const ARES_OPT_RESOLVCONF = @as(c_int, 1) << @as(c_int, 17);
pub const ARES_OPT_HOSTS_FILE = @as(c_int, 1) << @as(c_int, 18);
pub const ARES_NI_NOFQDN = @as(c_int, 1) << @as(c_int, 0);
pub const ARES_NI_NUMERICHOST = @as(c_int, 1) << @as(c_int, 1);
pub const ARES_NI_NAMEREQD = @as(c_int, 1) << @as(c_int, 2);
pub const ARES_NI_NUMERICSERV = @as(c_int, 1) << @as(c_int, 3);
pub const ARES_NI_DGRAM = @as(c_int, 1) << @as(c_int, 4);
pub const ARES_NI_TCP = @as(c_int, 0);
pub const ARES_NI_UDP = ARES_NI_DGRAM;
pub const ARES_NI_SCTP = @as(c_int, 1) << @as(c_int, 5);
pub const ARES_NI_DCCP = @as(c_int, 1) << @as(c_int, 6);
pub const ARES_NI_NUMERICSCOPE = @as(c_int, 1) << @as(c_int, 7);
pub const ARES_NI_LOOKUPHOST = @as(c_int, 1) << @as(c_int, 8);
pub const ARES_NI_LOOKUPSERVICE = @as(c_int, 1) << @as(c_int, 9);
pub const ARES_NI_IDN = @as(c_int, 1) << @as(c_int, 10);
pub const ARES_NI_IDN_ALLOW_UNASSIGNED = @as(c_int, 1) << @as(c_int, 11);
pub const ARES_NI_IDN_USE_STD3_ASCII_RULES = @as(c_int, 1) << @as(c_int, 12);
pub const ARES_AI_CANONNAME = @as(c_int, 1) << @as(c_int, 0);
pub const ARES_AI_NUMERICHOST = @as(c_int, 1) << @as(c_int, 1);
pub const ARES_AI_PASSIVE = @as(c_int, 1) << @as(c_int, 2);
pub const ARES_AI_NUMERICSERV = @as(c_int, 1) << @as(c_int, 3);
pub const ARES_AI_V4MAPPED = @as(c_int, 1) << @as(c_int, 4);
pub const ARES_AI_ALL = @as(c_int, 1) << @as(c_int, 5);
pub const ARES_AI_ADDRCONFIG = @as(c_int, 1) << @as(c_int, 6);
pub const ARES_AI_NOSORT = @as(c_int, 1) << @as(c_int, 7);
pub const ARES_AI_ENVHOSTS = @as(c_int, 1) << @as(c_int, 8);
pub const ARES_AI_IDN = @as(c_int, 1) << @as(c_int, 10);
pub const ARES_AI_IDN_ALLOW_UNASSIGNED = @as(c_int, 1) << @as(c_int, 11);
pub const ARES_AI_IDN_USE_STD3_ASCII_RULES = @as(c_int, 1) << @as(c_int, 12);
pub const ARES_AI_CANONIDN = @as(c_int, 1) << @as(c_int, 13);
pub const ARES_AI_MASK = (((((ARES_AI_CANONNAME | ARES_AI_NUMERICHOST) | ARES_AI_PASSIVE) | ARES_AI_NUMERICSERV) | ARES_AI_V4MAPPED) | ARES_AI_ALL) | ARES_AI_ADDRCONFIG;
pub const ARES_GETSOCK_MAXNUM = @as(c_int, 16);
pub inline fn ARES_GETSOCK_READABLE(bits: anytype, num: anytype) @TypeOf(bits & (@as(c_int, 1) << num)) {
    return bits & (@as(c_int, 1) << num);
}
pub inline fn ARES_GETSOCK_WRITABLE(bits: anytype, num: anytype) @TypeOf(bits & (@as(c_int, 1) << (num + ARES_GETSOCK_MAXNUM))) {
    return bits & (@as(c_int, 1) << (num + ARES_GETSOCK_MAXNUM));
}
pub const ARES_LIB_INIT_NONE = @as(c_int, 0);
pub const ARES_LIB_INIT_WIN32 = @as(c_int, 1) << @as(c_int, 0);
pub const ARES_LIB_INIT_ALL = ARES_LIB_INIT_WIN32;
pub const ARES_SOCKET_BAD = -@as(c_int, 1);
pub const ares_socket_typedef = "";
pub const ares_addrinfo_cname = AddrInfo_cname;
pub const ares_addrinfo_node = AddrInfo_node;
pub const ares_addrinfo = AddrInfo;
pub const ares_addrinfo_hints = AddrInfo_hints;
pub const ares_in6_addr = struct_ares_in6_addr;
pub const ares_addrttl = struct_ares_addrttl;
pub const ares_addr6ttl = struct_ares_addr6ttl;
pub const ares_caa_reply = struct_ares_caa_reply;
pub const ares_srv_reply = struct_ares_srv_reply;
pub const ares_mx_reply = struct_ares_mx_reply;
pub const ares_txt_reply = struct_ares_txt_reply;
pub const ares_txt_ext = struct_ares_txt_ext;
pub const ares_naptr_reply = struct_ares_naptr_reply;
pub const ares_soa_reply = struct_ares_soa_reply;
pub const ares_uri_reply = struct_ares_uri_reply;
pub const ares_addr_node = struct_ares_addr_node;
pub const ares_addr_port_node = struct_ares_addr_port_node;