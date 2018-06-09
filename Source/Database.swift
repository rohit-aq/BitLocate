//
//  Database.swift
//
//  Copyright (c) 2017 OpenLocate
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import SQLite3

enum SQLiteError: Error {
    case open(message: String)
    case prepare(message: String)
    case step(message: String)
    case bind(message: String)
}

protocol Database {
    var userVersion: Int { get set }

    @discardableResult
    func execute(statement: Statement) throws -> Result
    func begin()
    func commit()
    func rollback()
}

final class SQLiteDatabase: Database {
    fileprivate enum Constants {
        static let databaseName = "openlocate.sqlite3"
        static let databaseQueue = "openlocate.sqlite3.queue"
    }

    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let queue = DispatchQueue(label: Constants.databaseQueue, attributes: [])

    private let database: OpaquePointer
    private let fmt = DateFormatter()

    private init(database: OpaquePointer) {
        self.database = database
    }

    deinit {
        sqlite3_close(database)
    }

    private var errorMessage: String {
        return String(cString: sqlite3_errmsg(database))
    }
}

extension SQLiteDatabase {

    static func openLocateDatabase() throws -> SQLiteDatabase {
        guard let path = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first,
            let bundleIdentifier = Bundle(for: OpenLocate.self).bundleIdentifier else {

            throw SQLiteError.open(message: "Error getting directory")
        }

        let url = URL(fileURLWithPath: path).appendingPathComponent(bundleIdentifier, isDirectory: true)

        let attributes = [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: attributes)

        return try open(path: url.appendingPathComponent(Constants.databaseName, isDirectory: false).path)
    }

    static func open(path: String) throws -> SQLiteDatabase {
        var db: OpaquePointer?

        if sqlite3_open(path, &db) == SQLITE_OK, let db = db {
            return SQLiteDatabase(database: db)
        } else {
            let message: String

            if let database = db {
                defer {
                    sqlite3_close(database)
                }
                message = String(cString: sqlite3_errmsg(database))
            } else {
                message = "Error opening database"
            }

            throw SQLiteError.open(message: message)
        }
    }

    private func prepareStatement(_ sql: String) throws -> OpaquePointer {
        return try queue.sync { () -> OpaquePointer in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                let preparedStatement = statement else {
                    throw SQLiteError.prepare(message: errorMessage)
            }

            return preparedStatement
        }
    }

    private func bindParameter(_ statement: inout OpaquePointer, args: StatementArgs) throws {
        try queue.sync(execute: { () -> Void in
            let queryCount = sqlite3_bind_parameter_count(statement)

            if queryCount != args.count {
                throw SQLiteError.bind(message: errorMessage)
            }

            args.enumerated().forEach { index, object in
                _ = bindObject(
                    object: object,
                    column: index + 1,
                    statement: &statement
                )
            }
        })
    }

    private func bindObject(object: Any, column: Int, statement: inout OpaquePointer) -> CInt {
        let flag: CInt

        if let txt = object as? String {
            flag = sqlite3_bind_text(statement, CInt(column), txt, -1, sqliteTransient)
        } else if let data = object as? NSData {
            flag = sqlite3_bind_blob(statement, CInt(column), data.bytes, CInt(data.length), sqliteTransient)
        } else if let date = object as? Date {
            let txt = Formatter.sqliteDateFormatter.string(from: date)
            flag = sqlite3_bind_text(statement, CInt(column), txt, -1, sqliteTransient)
        } else if let val = object as? Bool {
            let num = val ? 1 : 0
            flag = sqlite3_bind_int(statement, CInt(column), CInt(num))
        } else if let val = object as? Double {
            flag = sqlite3_bind_double(statement, CInt(column), CDouble(val))
        } else if let val = object as? Int {
            flag = sqlite3_bind_int(statement, CInt(column), CInt(val))
        } else {
            flag = sqlite3_bind_null(statement, CInt(column))
        }

        return flag
    }
}

extension SQLiteDatabase {
    @discardableResult
    func execute(statement: Statement) throws -> Result {
        var preparedStatement = try prepareStatement(statement.statement)
        try bindParameter(&preparedStatement, args: statement.args)

        let result = SQLResult.Builder()
            .set(statement: preparedStatement)
            .set(queue: queue)
            .build()

        if !statement.cached {
            let code = result.code
            try checkResult(code)
        }

        return result
    }

    private func checkResult(_ code: CInt) throws {
        switch code {
        case SQLITE_DONE, SQLITE_OK, SQLITE_ROW:
            break
        case SQLITE_CONSTRAINT:
            throw SQLiteError.step(message: errorMessage)
        default:
            throw SQLiteError.step(message: "SQL error")
        }
    }
}

extension SQLiteDatabase {

    public var userVersion: Int {
        get {
            let statement = SQLStatement.Builder().set(query: "PRAGMA user_version;").build()
            if let result = try? execute(statement: statement) {
                _ = result.next()
                return Int(result.intValue(column: 0))
            }
            return 0
        }
        set {
            let statement = SQLStatement.Builder().set(query: "PRAGMA user_version = \(newValue)").build()
            _ = try? execute(statement: statement)
        }
    }

    func begin() {
        let query = "BEGIN EXCLUSIVE"
        let statement = SQLStatement.Builder()
        .set(query: query)
        .build()

        _ = try? execute(statement: statement)
    }

    func commit() {
        let query = "COMMIT"
        let statement = SQLStatement.Builder()
            .set(query: query)
            .build()

        _ = try? execute(statement: statement)
    }

    func rollback() {
        let query = "ROLLBACK"
        let statement = SQLStatement.Builder()
            .set(query: query)
            .build()

        _ = try? execute(statement: statement)
    }
}
