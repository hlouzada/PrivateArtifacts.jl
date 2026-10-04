# Matches C0 and C1 control characters. Bytes that are not valid UTF-8 never
# match, so callers check `isvalid` as well.
const CONTROL = r"[\x00-\x1f\x7f-\x9f]"

# A server or CLI must not drive the terminal through an error. `\u` escapes have
# four digits so that a following hex digit is not read as part of them.
function escape_controls(text::AbstractString)::String
    escaped(c) =
        !isvalid(c) ? join("\\x" * string(byte; base = 16, pad = 2) for byte in codeunits(string(c))) :
        c in ('\n', '\t') || !iscntrl(c) ? string(c) :
        "\\u" * string(UInt32(c); base = 16, pad = 4)
    join(escaped(c) for c in text)
end

# Signed download URLs keep their signature in the path or query, and a URL can
# hold a password.
function scrub(text::AbstractString)::String
    text = escape_controls(replace(text, "\r\n" => "\n"))
    text = replace(text, r"(?i)(https?://)[^\s\"/?#]*@" => s"\1")
    replace(text, r"(?i)(https?://[^\s\"/?#]*)[/?#][^\s\"]*" => s"\1/…")
end

shown(value)::String = escape_string(string(value))

unescape(path::AbstractString)::String = replace(path, r"%[0-9A-Fa-f]{2}" => hex -> String([parse(UInt8, hex[2:3]; base = 16)]))

# Encodes each UTF-8 byte of the characters that `pattern` matches.
percent_encode(text::AbstractString, pattern::Regex)::String =
    replace(text, pattern => c -> join("%" * uppercase(string(byte; base = 16, pad = 2)) for byte in codeunits(c)))
