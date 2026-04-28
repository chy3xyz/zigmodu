//! libpq C bindings - simple extern declarations using linked libpq library

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
    PGRES_BAD_RESPONSE = 3,
    PGRES_NONFATAL_ERROR = 4,
    PGRES_FATAL_ERROR = 5,
};

pub const Oid = c_uint;

pub extern "c" fn PQconnectdb(conninfo: [*c]const u8) ?*PGconn;
pub extern "c" fn PQfinish(conn: ?*PGconn) void;
pub extern "c" fn PQstatus(conn: ?*const PGconn) ConnStatusType;
pub extern "c" fn PQexec(conn: ?*PGconn, command: [*c]const u8) ?*PGresult;
pub extern "c" fn PQexecParams(
    conn: ?*PGconn,
    command: [*c]const u8,
    nParams: c_int,
    paramTypes: ?[*]const Oid,
    paramValues: ?[*]const ?[*]const u8,
    paramLengths: ?[*]const c_int,
    paramFormats: ?[*]const c_int,
    resultFormat: c_int,
) ?*PGresult;
pub extern "c" fn PQclear(res: ?*PGresult) void;
pub extern "c" fn PQresultStatus(res: ?*const PGresult) ExecStatusType;
pub extern "c" fn PQntuples(res: ?*const PGresult) c_int;
pub extern "c" fn PQnfields(res: ?*const PGresult) c_int;
pub extern "c" fn PQfname(res: ?*const PGresult, col: c_int) [*c]const u8;
pub extern "c" fn PQgetvalue(res: ?*const PGresult, row: c_int, col: c_int) [*c]const u8;
pub extern "c" fn PQgetisnull(res: ?*const PGresult, row: c_int, col: c_int) c_int;
pub extern "c" fn PQcmdTuples(res: ?*const PGresult) [*c]const u8;
pub extern "c" fn PQoidValue(res: ?*const PGresult) Oid;
pub extern "c" fn PQerrorMessage(conn: ?*const PGconn) [*c]const u8;
pub extern "c" fn PQprepare(conn: ?*PGconn, stmtName: [*c]const u8, query: [*c]const u8, nParams: c_int, paramTypes: ?[*]const Oid) ?*PGresult;
pub extern "c" fn PQexecPrepared(
    conn: ?*PGconn,
    stmtName: [*c]const u8,
    nParams: c_int,
    paramValues: ?[*]const ?[*]const u8,
    paramLengths: ?[*]const c_int,
    paramFormats: ?[*]const c_int,
    resultFormat: c_int,
) ?*PGresult;
pub extern "c" fn PQsetdbLogin(
    pghost: [*c]const u8,
    pgport: [*c]const u8,
    login_options: [*c]const u8,
    pgtty: [*c]const u8,
    dbname: [*c]const u8,
    login: [*c]const u8,
    passwd: [*c]const u8,
) ?*PGconn;
