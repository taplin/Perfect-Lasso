import Foundation

/// Shared helpers for the `Math_*` free-function family (Lasso 8.5
/// Language Guide Chapter 28, "Math Operations", Tables 10-12 — verified
/// directly against the PDF, including its own worked examples, rather
/// than inferred). The arithmetic symbols (`+`/`-`/`*`/`/`/`%`) already
/// work via `Evaluator.binary` — this covers the separate substitution-
/// tag dialect (`Math_Add`, `Math_Sub`, ...) real corpus commonly uses
/// instead, plus rounding/random/trig functions that have no symbol
/// equivalent at all.
enum LassoMathOperations {
    /// Extracts every positional (unlabeled) argument as a `Double`,
    /// alongside whether every one of them was a genuine `.integer`
    /// `LassoValue` — Ch. 28's own rule ("If all the parameters to a
    /// mathematical substitution tag are integers then the result will
    /// be an integer. If any of the parameter... is a decimal then the
    /// result will be a decimal value") keys off the VALUE'S TYPE, not
    /// just whether its numeric value happens to be a whole number, so
    /// this checks the `LassoValue` case directly rather than using
    /// `.number`'s looser parsing.
    static func operands(_ arguments: [EvaluatedArgument]) -> (values: [Double], allInteger: Bool) {
        var values: [Double] = []
        var allInteger = true
        for argument in arguments where argument.label == nil {
            if case let .integer(value) = argument.value {
                values.append(Double(value))
            } else {
                values.append(argument.value.number ?? 0)
                allInteger = false
            }
        }
        return (values, allInteger)
    }

    static func result(_ value: Double, allInteger: Bool) -> LassoValue {
        allInteger ? .integer(Int(value)) : .decimal(value)
    }
}
