import Foundation

/// Text entered in the launcher uses Windows quote and backslash rules.
/// Newlines are also separators so existing multiline input remains usable.
public enum LaunchArguments {
    public static func parse(_ text: String) -> [String] {
        let characters = Array(text)
        var index = 0
        var arguments: [String] = []
        while index < characters.count {
            while index < characters.count && characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            var argument = ""
            var quoted = false
            while index < characters.count && (quoted || !characters[index].isWhitespace) {
                var backslashes = 0
                while index < characters.count && characters[index] == "\\" {
                    backslashes += 1
                    index += 1
                }
                if index < characters.count && characters[index] == "\"" {
                    argument += String(repeating: "\\", count: backslashes / 2)
                    index += 1
                    if backslashes % 2 == 1 {
                        argument.append("\"")
                    } else if quoted && index < characters.count && characters[index] == "\"" {
                        argument.append("\"")
                        index += 1
                    } else {
                        quoted.toggle()
                    }
                } else {
                    argument += String(repeating: "\\", count: backslashes)
                    if index < characters.count && (quoted || !characters[index].isWhitespace) {
                        argument.append(characters[index])
                        index += 1
                    }
                }
            }
            arguments.append(argument)
        }
        return arguments
    }

    /// Quote saved values before editing so a path containing spaces stays one value.
    public static func format(_ arguments: [String]) -> String {
        arguments.map { argument in
            guard argument.isEmpty || argument.contains(where: { $0.isWhitespace || $0 == "\"" }) else {
                return argument
            }
            var result = "\""
            var backslashes = 0
            for character in argument {
                if character == "\\" {
                    backslashes += 1
                    continue
                }
                result += String(repeating: "\\", count: character == "\"" ? backslashes * 2 + 1 : backslashes)
                result.append(character)
                backslashes = 0
            }
            result += String(repeating: "\\", count: backslashes * 2) + "\""
            return result
        }.joined(separator: " ")
    }
}
