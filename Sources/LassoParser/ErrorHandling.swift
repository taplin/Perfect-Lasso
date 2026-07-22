import Foundation

/// `Fail`/`Fail_If` and the general `Error_*` tag family (Lasso 8.5
/// Language Guide Ch. 19 "Error Control", Table 3 "Error Tags" and
/// Table 4 "Error Type Tags"; `fail`/`fail_if` cross-checked against
/// lassoguide.com's Lasso 9 "Error Handling" page for the newer
/// message-only/optional-code call forms). Error codes verified
/// directly against Appendix A "Error Codes" Table 1 (`pdftotext
/// -layout`, since raw extraction interleaves the code/message columns
/// unreadably) and, for the handful only documented on the Lasso 9
/// side, lassoguide.com's own "Lasso Error Codes and Messages" table.
///
/// `handle`/`handle_failure` (Ch. "Error Handling") are now implemented
/// too — see `Evaluator.registerHandle`/`drainPendingHandlers` and
/// `Renderer.render(_:)`'s own doc comment. Deliberately narrower than
/// the full documented mechanism: each `Renderer.render(_:)` call is its
/// own "container" (registration scope), drained (handlers invoked in
/// registration order, `handle_failure` only on an actual failure) once
/// that call finishes — whether normally or via a thrown error — and the
/// original error, if any, always propagates unchanged afterward. What's
/// still NOT implemented: `Fail`'s documented "halt the rest of the
/// current container's statements and jump straight to its handlers"
/// control-flow signal — `fail`/`fail_if` still just throw the existing
/// `LassoRecoverableError` (a plain thrown Swift error), which this
/// codebase's ordinary error propagation already carries up through
/// enclosing `render(_:)` calls (now draining `handle` along the way)
/// to `protect` or an unhandled failure exactly as before. No corpus
/// evidence has needed the distinction between that and a genuine
/// "jump directly to the handlers, skip everything in between" signal.
enum LassoErrorHandling {
    /// Verified against Appendix A Table 1 (pp. 822-824) unless noted.
    enum Code {
        static let noError = 0
        // Action Errors (p.823).
        static let deleteError = -9957
        static let updateError = -9958
        static let addError = -9959
        static let fieldRestriction = -9960
        // Security Errors (p.823).
        static let noPermission = -9961
        static let invalidDatabase = -9962
        static let invalidPassword = -9963
        static let invalidUsername = -9964
        static let networkError = -9965
        static let resourceNotFound = -9967
        // Internal Errors (p.823).
        static let invalidParameter = -9956
        // The remainder are documented only on lassoguide.com's Lasso 9
        // "Error Handling" page's own "Lasso Error Codes and Messages"
        // table (not present in the 8.5 PDF's Appendix A at all —
        // Lasso 9 added several new named codes in the same numeric
        // neighborhood).
        static let fileNotFound = 404
        static let runtimeAssertion = -9945
        static let aborted = -9946
        static let methodNotFound = -9948
        static let divideByZero = -9950
        // `fail`/`fail_if` below default to this for their message-only
        // call forms, which don't specify a code — modeled on the
        // Guide's own repeated use of -1 for generic/custom errors
        // (p.263's `[Error_SetErrorCode: -1]` example, p.267's `[Fail:
        // -1, 'An unrecoverable error occurred']`), though the Guide
        // never states this as a formal rule — a THIRD example (p.268's
        // Protect/Handle_Error walkthrough) uses -1 and -2 side by side
        // as two equally-arbitrary custom codes with no special meaning
        // attached to -1 specifically, so this is a reasonable default
        // inferred from repeated usage, not a documented convention.
        static let genericCustom = -1
    }

    static func registerDefaultFunctions(into registry: inout LassoNativeRegistry) {
        // `[Fail]`: "Takes two parameters: an integer error code and a
        // string error message." lassoguide.com's Lasso 9 form also
        // allows a message-only call (`fail(msg::string)`), defaulting
        // to `Code.genericCustom` since no code is given.
        registry.register("fail") { arguments, _ in
            let (code, message) = failArguments(arguments)
            throw LassoRecoverableError(LassoErrorState(code: code, message: message, kind: "fail"))
        }
        // `[Fail_If]`: "The first parameter... is a conditional
        // expression. The last two parameters are the same integer
        // error code and string error message as in the [Fail] tag."
        // lassoguide.com's Lasso 9 form also allows a 2-parameter
        // (condition, message) call, same default-code convention as
        // `fail` above.
        registry.register("fail_if") { arguments, _ in
            guard arguments.positionalValue(at: 0)?.isTruthy == true else { return .void }
            let (code, message) = failArguments(Array(arguments.dropFirst()))
            throw LassoRecoverableError(LassoErrorState(code: code, message: message, kind: "fail"))
        }

        // Table 3 "Error Tags" — `error_currenterror` already exists
        // (`Runtime.swift`); these are its documented siblings.
        registry.register("error_code") { _, context in .integer(context.currentError.code) }
        registry.register("error_msg") { _, context in .string(context.currentError.message) }
        registry.register("error_push") { _, context in
            context.pushError()
            return .void
        }
        registry.register("error_pop") { _, context in
            context.popError()
            return .void
        }
        registry.register("error_reset") { _, context in
            context.clearError()
            return .void
        }
        registry.register("error_seterrorcode") { arguments, context in
            let code = arguments.first?.value.number.map(Int.init) ?? 0
            context.setError(LassoErrorState(code: code, message: context.currentError.message, kind: "custom"))
            return .void
        }
        registry.register("error_seterrormessage") { arguments, context in
            let message = arguments.first?.value.outputString ?? ""
            context.setError(LassoErrorState(code: context.currentError.code, message: message, kind: "custom"))
            return .void
        }

        // Table 4 "Error Type Tags" (p.264-265) has 14 rows; 10 are
        // registered below. Deliberately NOT implemented, disclosed
        // rather than silently dropped: `Error_DatabaseConnectionUnavailable`/
        // `Error_DatabaseTimeout`/`Error_FileNotFound`/`Error_OutOfMemory`/
        // `Error_RequiredFieldMissing` — none map to a single clean
        // Appendix A numeric code the way the other ten do (`p.263`'s
        // -1/-2 custom-code examples aside, Table 4's entries otherwise
        // correspond 1:1 with real Table 1 codes; these five don't).
        //
        // Named constant accessors, NOT `currentError` state: bare,
        // each returns its own fixed message; with `-ErrorCode`, its
        // own fixed code. Matches `error_currenterror`'s existing
        // dual-mode pattern exactly, and the Guide's own worked example
        // chaining one straight into a setter: `[Error_SetErrorCode:
        // (Error_AddError: -ErrorCode)]`.
        registerNamedError(&registry, "error_adderror", code: Code.addError, message: "An error occurred during an -Add action.")
        registerNamedError(&registry, "error_deleteerror", code: Code.deleteError, message: "An error occurred during a -Delete action.")
        registerNamedError(&registry, "error_updateerror", code: Code.updateError, message: "An error occurred during an -Update action.")
        registerNamedError(&registry, "error_fieldrestriction", code: Code.fieldRestriction, message: "A field security restriction prevented the action from being executed.")
        // "Synonym is [Error_ColumnRestriction]" (Table 4's own text).
        registerNamedError(&registry, "error_columnrestriction", code: Code.fieldRestriction, message: "A field security restriction prevented the action from being executed.")
        registerNamedError(&registry, "error_nopermission", code: Code.noPermission, message: "The current user does not have permission to perform the requested database action.")
        registerNamedError(&registry, "error_invaliddatabase", code: Code.invalidDatabase, message: "The specified database is not configured within Lasso Administration.")
        registerNamedError(&registry, "error_invalidpassword", code: Code.invalidPassword, message: "The password for the specified username is invalid.")
        registerNamedError(&registry, "error_invalidusername", code: Code.invalidUsername, message: "The specified username cannot be found in the users database within Lasso security.")
        registerNamedError(&registry, "error_noerror", code: Code.noError, message: "No Error")

        // lassoguide.com's Lasso 9 `error_code_*`/`error_msg_*` plain-
        // value forms — used directly as values (`error_code_divideByZero`),
        // not as `-ErrorCode`-flagged dual-mode tags like Table 4 above.
        for (name, code, message) in [
            ("noerror", Code.noError, "No error"),
            ("filenotfound", Code.fileNotFound, "File not found"),
            ("runtimeassertion", Code.runtimeAssertion, "Runtime assertion"),
            ("aborted", Code.aborted, "General Abort"),
            ("methodnotfound", Code.methodNotFound, "Method not found"),
            ("divideByZero", Code.divideByZero, "Divide by Zero"),
            ("invalidparameter", Code.invalidParameter, "Invalid parameter"),
            ("networkerror", Code.networkError, "Network error"),
            ("resnotfound", Code.resourceNotFound, "Resource not found"),
        ] {
            registry.register("error_code_\(name)") { _, _ in .integer(code) }
            registry.register("error_msg_\(name)") { _, _ in .string(message) }
        }
    }

    /// Shared by `fail`/`fail_if`: the message-only Lasso 9 form has
    /// exactly one positional argument (the message); the code+message
    /// form (both Lasso 8.5's own documented shape and Lasso 9's
    /// alternate signature) has two or more, the first being the code.
    private static func failArguments(_ arguments: [EvaluatedArgument]) -> (code: Int, message: String) {
        let positionals = arguments.filter { $0.label == nil }.map(\.value)
        guard positionals.count >= 2 else {
            return (Code.genericCustom, positionals.first?.outputString ?? "")
        }
        return (Int(positionals[0].number ?? 0), positionals[1].outputString)
    }

    private static func registerNamedError(_ registry: inout LassoNativeRegistry, _ name: String, code: Int, message: String) {
        registry.register(name) { arguments, _ in
            arguments.hasTruthyFlag("errorcode") ? .integer(code) : .string(message)
        }
    }
}
