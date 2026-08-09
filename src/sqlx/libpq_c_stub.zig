//! Stub libpq bindings when postgres driver is disabled (no libpq link).

pub const PGconn = opaque {};
pub const PGresult = opaque {};

pub const ConnStatusType = enum(c_int) {
    CONNECTION_OK = 0,
    CONNECTION_BAD = 1,
};

pub const ExecStatusType = enum(c_int) {
    PGRES_EMPTY_QUERY = 0,
    PGRES_COMMAND_OK = 1,
    PGRES_TUPLES_OK = 2,
    PGRES_COPY_OUT = 3,
    PGRES_COPY_IN = 4,
    PGRES_BAD_RESPONSE = 5,
    PGRES_NONFATAL_ERROR = 6,
    PGRES_FATAL_ERROR = 7,
    PGRES_COPY_BOTH = 8,
    PGRES_SINGLE_TUPLE = 9,
};

pub const Oid = c_uint;

pub fn PQconnectdb(_: [*c]const u8) ?*PGconn {
    return null;
}
pub fn PQfinish(_: ?*PGconn) void {}
pub fn PQstatus(_: ?*const PGconn) ConnStatusType {
    return .CONNECTION_BAD;
}

pub fn PQsocket(_: ?*const PGconn) c_int {
    return -1; // no real socket in stub mode
}
pub fn PQexec(_: ?*PGconn, _: [*c]const u8) ?*PGresult {
    return null;
}
pub fn PQexecParams(_: ?*PGconn, _: [*c]const u8, _: c_int, _: ?[*]const Oid, _: ?[*]const ?[*]const u8, _: ?[*]const c_int, _: ?[*]const c_int, _: c_int) ?*PGresult {
    return null;
}
pub fn PQclear(_: ?*PGresult) void {}
pub fn PQresultStatus(_: ?*const PGresult) ExecStatusType {
    return .PGRES_FATAL_ERROR;
}
pub fn PQntuples(_: ?*const PGresult) c_int {
    return 0;
}
pub fn PQnfields(_: ?*const PGresult) c_int {
    return 0;
}
pub fn PQfname(_: ?*const PGresult, _: c_int) [*c]const u8 {
    return "";
}
pub fn PQgetvalue(_: ?*const PGresult, _: c_int, _: c_int) [*c]const u8 {
    return "";
}
pub fn PQgetisnull(_: ?*const PGresult, _: c_int, _: c_int) c_int {
    return 1;
}
pub fn PQgetlength(_: ?*const PGresult, _: c_int, _: c_int) c_int {
    return 0;
}
pub fn PQfformat(_: ?*const PGresult, _: c_int) c_int {
    return 0;
}
pub fn PQftype(_: ?*const PGresult, _: c_int) Oid {
    return 0;
}
pub fn PQcmdTuples(_: ?*const PGresult) [*c]const u8 {
    return "0";
}
pub fn PQoidValue(_: ?*const PGresult) Oid {
    return 0;
}
pub fn PQerrorMessage(_: ?*const PGconn) [*c]const u8 {
    return "postgres driver disabled";
}
pub fn PQresultErrorField(_: ?*const PGresult, _: c_int) [*c]const u8 {
    return "";
}
pub fn PQresultErrorMessage(_: ?*const PGresult) [*c]const u8 {
    return "postgres driver disabled";
}
pub fn PQprepare(_: ?*PGconn, _: [*c]const u8, _: [*c]const u8, _: c_int, _: ?[*]const Oid) ?*PGresult {
    return null;
}
pub fn PQexecPrepared(_: ?*PGconn, _: [*c]const u8, _: c_int, _: ?[*]const ?[*]const u8, _: ?[*]const c_int, _: ?[*]const c_int, _: c_int) ?*PGresult {
    return null;
}
pub fn PQsendQueryParams(_: ?*PGconn, _: [*c]const u8, _: c_int, _: ?[*]const Oid, _: ?[*]const ?[*]const u8, _: ?[*]const c_int, _: ?[*]const c_int, _: c_int) c_int {
    return 0;
}
pub fn PQsetSingleRowMode(_: ?*PGconn) c_int {
    return 0;
}
pub fn PQgetResult(_: ?*PGconn) ?*PGresult {
    return null;
}
pub fn PQconsumeInput(_: ?*PGconn) c_int {
    return 0;
}
pub fn PQisBusy(_: ?*PGconn) c_int {
    return 0;
}
pub fn PQputCopyData(_: ?*PGconn, _: [*c]const u8, _: c_int) c_int {
    return -1;
}
pub fn PQputCopyEnd(_: ?*PGconn, _: [*c]const u8) c_int {
    return -1;
}
pub fn PQsetdbLogin(_: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) ?*PGconn {
    return null;
}
