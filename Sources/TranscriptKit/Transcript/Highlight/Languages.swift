import Foundation

/// How one language family is tokenized.
struct LanguageSpec: Sendable {
    enum Family: Sendable { case generic, json, yaml, markup, css, shell, diff }

    var name: String
    var family: Family = .generic
    var keywords: Set<String> = []
    var types: Set<String> = []
    var literals: Set<String> = []
    var lineComments: [String] = []
    var blockComments: [(open: String, close: String)] = []
    /// String delimiters; triple-quoted forms are listed first.
    var strings: [String] = ["\"", "'"]
    /// Delimiters whose strings may span lines (template literals, raw strings).
    var multilineStrings: Set<String> = []
    var capitalizedAreTypes = false
    var caseInsensitive = false
    /// Extra identifier characters (`$` in JS and shell, `-` in CSS).
    var identifierExtras: Set<UInt16> = []
    /// Prefix for attributes/decorators/macros (`@` in Swift, Python, TS; `#` in Rust attributes).
    var metaPrefix: UInt16?
}

enum Languages {
    static func spec(for language: String?) -> LanguageSpec? {
        guard let raw = language?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let name = aliases[raw] ?? raw
        return specs[name]
    }

    static let aliases: [String: String] = [
        "ts": "typescript", "tsx": "typescript", "js": "typescript", "javascript": "typescript", "jsx": "typescript",
        "mjs": "typescript", "cjs": "typescript", "py": "python", "python3": "python", "rs": "rust", "golang": "go",
        "jsonc": "json", "json5": "json", "yml": "yaml", "sh": "shell", "bash": "shell", "zsh": "shell",
        "console": "shell", "shellsession": "shell", "fish": "shell", "xml": "html", "svg": "html", "xhtml": "html",
        "vue": "html", "scss": "css", "less": "css", "patch": "diff", "c++": "cpp", "cc": "cpp", "hpp": "cpp", "h": "c",
        "objc": "c", "objective-c": "c", "kt": "kotlin", "rb": "ruby", "postgres": "sql", "postgresql": "sql",
        "mysql": "sql", "sqlite": "sql",
    ]

    static let specs: [String: LanguageSpec] = {
        var all: [String: LanguageSpec] = [:]
        func add(_ spec: LanguageSpec) { all[spec.name] = spec }
        let cStyle = [(open: "/*", close: "*/")]

        add(
            LanguageSpec(
                name: "swift",
                keywords: words(
                    "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw throws switch where while as is try await async actor nonisolated isolated some any self Self super get set willSet didSet mutating nonmutating lazy weak unowned override final required convenience dynamic indirect consuming borrowing sending macro package"),
                types: words("Int Double Float String Bool Character Array Dictionary Set Optional Void Any AnyObject Never Error Result Task"),
                literals: words("true false nil"), lineComments: ["//"], blockComments: cStyle,
                strings: ["\"\"\"", "\""], multilineStrings: ["\"\"\""], capitalizedAreTypes: true, metaPrefix: 64))
        add(
            LanguageSpec(
                name: "typescript",
                keywords: words(
                    "abstract as async await break case catch class const constructor continue debugger declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let module namespace new of private protected public readonly return satisfies set static super switch this throw try type typeof var void while with yield"),
                types: words("string number boolean any unknown never object symbol bigint void Promise Array Record Map Set Partial Readonly"),
                literals: words("true false null undefined NaN Infinity"), lineComments: ["//"], blockComments: cStyle,
                strings: ["\"", "'", "`"], multilineStrings: ["`"], capitalizedAreTypes: true, identifierExtras: [36],
                metaPrefix: 64))
        add(
            LanguageSpec(
                name: "python",
                keywords: words(
                    "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls"),
                types: words("int float str bool list dict set tuple bytes object type None Exception"),
                literals: words("True False None"), lineComments: ["#"], strings: ["\"\"\"", "'''", "\"", "'"],
                multilineStrings: ["\"\"\"", "'''"], capitalizedAreTypes: true, metaPrefix: 64))
        add(
            LanguageSpec(
                name: "rust",
                keywords: words(
                    "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while"),
                types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc"),
                literals: words("true false None Some Ok Err"), lineComments: ["//"], blockComments: cStyle,
                strings: ["\""], capitalizedAreTypes: true, metaPrefix: 35))
        add(
            LanguageSpec(
                name: "go",
                keywords: words(
                    "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
                types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any"),
                literals: words("true false nil iota"), lineComments: ["//"], blockComments: cStyle,
                strings: ["\"", "`", "'"], multilineStrings: ["`"]))
        add(
            LanguageSpec(
                name: "c",
                keywords: words(
                    "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while @interface @implementation @end @property"),
                types: words("int char float double void long short unsigned signed bool size_t uint8_t uint32_t int32_t int64_t id BOOL"),
                literals: words("true false NULL nil YES NO"), lineComments: ["//"], blockComments: cStyle,
                strings: ["\"", "'"], metaPrefix: 35))
        var cpp = all["c"]!
        cpp.name = "cpp"
        cpp.keywords.formUnion(
            words("class namespace template typename public private protected virtual override new delete this using try catch throw constexpr auto nullptr noexcept"))
        cpp.literals.insert("nullptr")
        add(cpp)
        add(
            LanguageSpec(
                name: "java",
                keywords: words(
                    "abstract assert break case catch class const continue default do else enum extends final finally for if implements import instanceof interface native new package private protected public return static super switch synchronized this throw throws try void volatile while var record"),
                types: words("int long short byte char float double boolean String Object"), literals: words("true false null"),
                lineComments: ["//"], blockComments: cStyle, strings: ["\"", "'"], capitalizedAreTypes: true, metaPrefix: 64))
        add(
            LanguageSpec(
                name: "kotlin",
                keywords: words(
                    "as break class continue do else for fun if in interface is object package return super this throw try typealias val var when while by catch constructor data enum finally get import init internal open override private protected public sealed set suspend"),
                types: words("Int Long String Boolean Double Float Unit Any Nothing List Map"), literals: words("true false null"),
                lineComments: ["//"], blockComments: cStyle, strings: ["\"\"\"", "\"", "'"], multilineStrings: ["\"\"\""],
                capitalizedAreTypes: true, metaPrefix: 64))
        add(
            LanguageSpec(
                name: "ruby",
                keywords: words(
                    "alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require attr_accessor"),
                literals: words("true false nil"), lineComments: ["#"], strings: ["\"", "'"], capitalizedAreTypes: true,
                metaPrefix: 58))
        add(
            LanguageSpec(
                name: "sql",
                keywords: words(
                    "select from where and or not insert into values update set delete create table index view drop alter add column primary key foreign references join left right inner outer full on as group by order having limit offset distinct union all case when then else end is null like in exists between returning with begin commit rollback transaction default unique check constraint if"),
                types: words("integer int bigint smallint text varchar char boolean real double numeric decimal date time timestamp blob json jsonb uuid serial"),
                literals: words("true false null"), lineComments: ["--"], blockComments: cStyle, strings: ["'", "\""],
                caseInsensitive: true))
        add(LanguageSpec(name: "json", family: .json, literals: words("true false null")))
        add(LanguageSpec(name: "yaml", family: .yaml, literals: words("true false null yes no on off ~")))
        add(LanguageSpec(name: "html", family: .markup))
        add(LanguageSpec(name: "css", family: .css, keywords: words("!important"), blockComments: cStyle))
        add(
            LanguageSpec(
                name: "shell", family: .shell,
                keywords: words(
                    "if then else elif fi for while until do done case esac in function return export local readonly unset set source alias exit"),
                lineComments: ["#"], identifierExtras: [45]))
        add(LanguageSpec(name: "diff", family: .diff))
        return all
    }()

    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }
}
