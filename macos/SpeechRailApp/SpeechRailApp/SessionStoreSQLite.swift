import Foundation
import SQLite3

/// SQLite 句柄的持有者。用一个小盒子而不是 actor 的存储属性，是为了让关闭动作
/// 跟着对象生命周期走：actor 的 `deinit` 在 Swift 6 里是 nonisolated，直接访问非 Sendable
/// 的 `OpaquePointer` 存储属性会被拒。盒子只在 actor 内部被触碰，所以这里的
/// `@unchecked Sendable` 说的是「没有并发访问」，不是「可以并发访问」。
final class SQLiteHandle: @unchecked Sendable {
    var pointer: OpaquePointer?

    deinit {
        if let pointer {
            sqlite3_close_v2(pointer)
        }
    }
}

extension SessionStore {

// MARK: - SQLite 薄封装

enum SQLArgument {
    case text(String)
    case int(Int)
    case real(Double)
}

func requireHandle() throws -> OpaquePointer {
    guard let pointer = handle.pointer else {
        throw SessionStoreError.storageUnavailable
    }
    return pointer
}

func execute(_ sql: String) throws {
    let pointer = try requireHandle()
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(pointer, sql, nil, nil, &error) == SQLITE_OK else {
        let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(pointer))
        sqlite3_free(error)
        throw SessionStoreError.statementFailed(detail)
    }
}

@discardableResult
func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    let pointer = try requireHandle()
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw SessionStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
}

@discardableResult
func step(_ statement: OpaquePointer) throws -> Int32 {
    let status = sqlite3_step(statement)
    switch status {
    case SQLITE_ROW, SQLITE_DONE:
        return status
    default:
        let pointer = try requireHandle()
        throw SessionStoreError.statementFailed(String(cString: sqlite3_errmsg(pointer)))
    }
}

func scalarInt(_ sql: String, args: [SQLArgument] = []) throws -> Int? {
    try withStatement(sql) { statement in
        for (offset, argument) in args.enumerated() {
            bindArgument(statement, Int32(offset + 1), argument)
        }
        guard try step(statement) == SQLITE_ROW else { return nil }
        return Int(columnInt(statement, 0))
    }
}

/// 名字不能叫 `bind`：那会遮蔽文件级的 `bind(_:_:_:)`，于是所有通过 `withStatement`
/// 写值的调用点都会报「cannot convert value of type 'String' to 'SQLArgument'」。
func bindArgument(_ statement: OpaquePointer, _ index: Int32, _ argument: SQLArgument) {
    switch argument {
    case .text(let value): bind(statement, index, value)
    case .int(let value): bind(statement, index, value)
    case .real(let value): bind(statement, index, value)
    }
}
}

// MARK: - 绑定与取值

func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
    if let value {
        // `SQLITE_TRANSIENT`：让 SQLite 复制字符串，而不是持有我们那个临时缓冲区的指针。
        // 写成内联表达式而不是文件级常量：函数类型的全局存储属性在严格并发下会要求 Sendable。
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    } else {
        sqlite3_bind_null(statement, index)
    }
}

func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
    if let value {
        sqlite3_bind_double(statement, index, value)
    } else {
        sqlite3_bind_null(statement, index)
    }
}

func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
    if let value {
        sqlite3_bind_int64(statement, index, Int64(value))
    } else {
        sqlite3_bind_null(statement, index)
    }
}

func columnIsNull(_ statement: OpaquePointer, _ index: Int32) -> Bool {
    sqlite3_column_type(statement, index) == SQLITE_NULL
}

func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard !columnIsNull(statement, index), let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
}

func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double {
    sqlite3_column_double(statement, index)
}

/// 可空的时间列。**NULL 必须读成 nil，不能读成 0**——`valid_to = 0`
/// 的意思是"1970 年就失效了"，把"还没失效"写成这个是在编造事实。
func columnDoubleOrNil(_ statement: OpaquePointer, _ index: Int32) -> Double? {
    guard !columnIsNull(statement, index) else { return nil }
    return sqlite3_column_double(statement, index)
}

func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
    sqlite3_column_int64(statement, index)
}
