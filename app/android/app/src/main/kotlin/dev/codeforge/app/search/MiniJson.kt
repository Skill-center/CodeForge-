package dev.codeforge.app.search

/**
 * Reads one JSON document (Phase 4 W6: ripgrep's `--json` lines) into
 * Kotlin values: Map, List, String, Long or Double, Boolean and null.
 * CodeForge's own, so the same code runs on the device and in the JVM tests,
 * where Android's org.json is only a stub. Throws IllegalArgumentException
 * on anything that is not JSON.
 */
class MiniJson private constructor(private val text: String) {
    private var at = 0

    private fun document(): Any? {
        val value = value()
        space()
        if (at != text.length) fail("text after the document")
        return value
    }

    private fun value(): Any? {
        space()
        if (at >= text.length) fail("the document ended early")
        return when (val c = text[at]) {
            '{' -> obj()
            '[' -> array()
            '"' -> string()
            't' -> word("true", true)
            'f' -> word("false", false)
            'n' -> word("null", null)
            else -> if (c == '-' || c in '0'..'9') number() else fail("unexpected '$c'")
        }
    }

    private fun obj(): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        at += 1
        space()
        if (peek() == '}') {
            at += 1
            return out
        }
        while (true) {
            space()
            if (peek() != '"') fail("a key must be a string")
            val key = string()
            space()
            expect(':')
            out[key] = value()
            space()
            when (peek()) {
                ',' -> at += 1
                '}' -> {
                    at += 1
                    return out
                }
                else -> fail("expected , or }")
            }
        }
    }

    private fun array(): List<Any?> {
        val out = ArrayList<Any?>()
        at += 1
        space()
        if (peek() == ']') {
            at += 1
            return out
        }
        while (true) {
            out.add(value())
            space()
            when (peek()) {
                ',' -> at += 1
                ']' -> {
                    at += 1
                    return out
                }
                else -> fail("expected , or ]")
            }
        }
    }

    private fun string(): String {
        at += 1
        val out = StringBuilder()
        while (true) {
            if (at >= text.length) fail("a string never ends")
            val c = text[at++]
            when {
                c == '"' -> return out.toString()
                c == '\\' -> {
                    if (at >= text.length) fail("a string never ends")
                    when (val e = text[at++]) {
                        '"', '\\', '/' -> out.append(e)
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> {
                            if (at + 4 > text.length) fail("a short \\u escape")
                            val code = text.substring(at, at + 4).toIntOrNull(16) ?: fail("a bad \\u escape")
                            out.append(code.toChar())
                            at += 4
                        }
                        else -> fail("a bad escape \\$e")
                    }
                }
                c < ' ' -> fail("a control character in a string")
                else -> out.append(c)
            }
        }
    }

    private fun number(): Any {
        val start = at
        if (peek() == '-') at += 1
        while (at < text.length && text[at] in '0'..'9') at += 1
        var whole = true
        if (peek() == '.') {
            whole = false
            at += 1
            while (at < text.length && text[at] in '0'..'9') at += 1
        }
        if (peek() == 'e' || peek() == 'E') {
            whole = false
            at += 1
            if (peek() == '+' || peek() == '-') at += 1
            while (at < text.length && text[at] in '0'..'9') at += 1
        }
        val literal = text.substring(start, at)
        return (if (whole) literal.toLongOrNull() else literal.toDoubleOrNull()) ?: fail("a bad number $literal")
    }

    private fun word(literal: String, value: Any?): Any? {
        if (!text.startsWith(literal, at)) fail("unexpected text")
        at += literal.length
        return value
    }

    private fun space() {
        while (at < text.length && (text[at] == ' ' || text[at] == '\n' || text[at] == '\r' || text[at] == '\t')) at += 1
    }

    private fun peek(): Char = if (at < text.length) text[at] else '\u0000'

    private fun expect(c: Char) {
        if (peek() != c) fail("expected $c")
        at += 1
    }

    private fun fail(why: String): Nothing = throw IllegalArgumentException("not JSON at $at: $why")

    companion object {
        fun parse(text: String): Any? = MiniJson(text).document()
    }
}
