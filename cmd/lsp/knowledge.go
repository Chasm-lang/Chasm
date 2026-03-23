package main

// builtinDocs maps builtin names to markdown hover documentation.
var builtinDocs = map[string]string{
	// ---- keywords ----
	"def":        "**def** — declare a public function\n```chasm\ndef name(param :: type) :: ret do\n  ...\nend\n```",
	"defp":       "**defp** — declare a private function\n```chasm\ndefp name(param :: type) :: ret do\n  ...\nend\n```",
	"defstruct":  "**defstruct** — declare a struct type\n```chasm\ndefstruct Vec2 do\n  x :: float\n  y :: float\nend\n```",
	"enum":       "**enum** — declare a tagged enum\n```chasm\nenum State { Idle, Running, Dead }\n```",
	"if":         "**if** — conditional branch\n```chasm\nif cond do\n  ...\nelse\n  ...\nend\n```",
	"while":      "**while** — conditional loop\n```chasm\nwhile cond do\n  ...\nend\n```",
	"for":        "**for** — range or array iteration\n```chasm\nfor i in 0..10 do\n  ...\nend\n```",
	"return":     "**return** — return a value from a function",
	"break":      "**break** — exit the nearest enclosing loop",
	"continue":   "**continue** — skip to the next loop iteration",
	"case":       "**case** — pattern match\n```chasm\ncase val do\n  when :a -> 1\n  _       -> 0\nend\n```",
	"import":     "**import** — import another Chasm file\n```chasm\nimport \"std/math\"\n```",
	"frame":      "**frame** lifetime — value is cleared every tick",
	"script":     "**script** lifetime — value survives ticks, reset on hot-reload",
	"persistent": "**persistent** lifetime — value survives until process exit",
	"true":       "Boolean literal `true`",
	"false":      "Boolean literal `false`",
	"and":        "**and** — logical AND operator",
	"or":         "**or** — logical OR operator",
	"not":        "**not** — logical NOT operator",

	// ---- lifetime promotions ----
	"copy_to_script": "```chasm\ncopy_to_script(x)\n```\nCopies `x` into the script arena. Promotes frame → script lifetime.",
	"persist_copy":   "```chasm\npersist_copy(x)\n```\nCopies `x` into the persistent arena. Promotes any → persistent lifetime.",

	// ---- math ----
	"abs":         "```chasm\nabs(v :: float) :: float\n```\nAbsolute value.",
	"sqrt":        "```chasm\nsqrt(v :: float) :: float\n```\nSquare root.",
	"pow":         "```chasm\npow(b :: float, e :: float) :: float\n```\n`b` raised to the power `e`.",
	"sin":         "```chasm\nsin(v :: float) :: float\n```\nSine (radians).",
	"cos":         "```chasm\ncos(v :: float) :: float\n```\nCosine (radians).",
	"tan":         "```chasm\ntan(v :: float) :: float\n```\nTangent (radians).",
	"atan2":       "```chasm\natan2(y :: float, x :: float) :: float\n```\nArctangent of y/x.",
	"floor":       "```chasm\nfloor(v :: float) :: float\n```\nRound down.",
	"ceil":        "```chasm\nceil(v :: float) :: float\n```\nRound up.",
	"round":       "```chasm\nround(v :: float) :: float\n```\nRound to nearest.",
	"fract":       "```chasm\nfract(v :: float) :: float\n```\nFractional part (`v - floor(v)`).",
	"sign":        "```chasm\nsign(v :: float) :: float\n```\nReturns -1.0, 0.0, or 1.0.",
	"min":         "```chasm\nmin(a :: float, b :: float) :: float\n```\nMinimum of two values.",
	"max":         "```chasm\nmax(a :: float, b :: float) :: float\n```\nMaximum of two values.",
	"clamp":       "```chasm\nclamp(v :: float, lo :: float, hi :: float) :: float\n```\nClamp `v` between `lo` and `hi`.",
	"lerp":        "```chasm\nlerp(a :: float, b :: float, t :: float) :: float\n```\nLinear interpolation.",
	"scale":       "```chasm\nscale(v :: float, factor :: float) :: float\n```\nMultiply `v` by `factor`.",
	"wrap":        "```chasm\nwrap(v :: float, lo :: float, hi :: float) :: float\n```\nWrap `v` into `[lo, hi)`.",
	"snap":        "```chasm\nsnap(v :: float, step :: float) :: float\n```\nRound to nearest multiple of `step`.",
	"smooth_step": "```chasm\nsmooth_step(a :: float, b :: float, t :: float) :: float\n```\nSmooth Hermite interpolation.",
	"move_toward": "```chasm\nmove_toward(cur :: float, target :: float, step :: float) :: float\n```\nMove `cur` toward `target` by at most `step`.",
	"angle_diff":  "```chasm\nangle_diff(a :: float, b :: float) :: float\n```\nShortest signed angle difference (radians).",
	"deg_to_rad":  "```chasm\ndeg_to_rad(d :: float) :: float\n```\nDegrees to radians.",
	"rad_to_deg":  "```chasm\nrad_to_deg(r :: float) :: float\n```\nRadians to degrees.",
	"ping_pong":   "```chasm\nping_pong(t :: float, len :: float) :: float\n```\nBounce `t` back and forth over `[0, len]`.",

	// ---- vec2 ----
	"vec2_len":    "```chasm\nvec2_len(x :: float, y :: float) :: float\n```\nLength of 2D vector.",
	"vec2_dot":    "```chasm\nvec2_dot(ax :: float, ay :: float, bx :: float, by :: float) :: float\n```\nDot product.",
	"vec2_dist":   "```chasm\nvec2_dist(ax :: float, ay :: float, bx :: float, by :: float) :: float\n```\nDistance between two points.",
	"vec2_angle":  "```chasm\nvec2_angle(x :: float, y :: float) :: float\n```\nAngle of vector (radians).",
	"vec2_norm_x": "```chasm\nvec2_norm_x(x :: float, y :: float) :: float\n```\nX component of normalised vector.",
	"vec2_norm_y": "```chasm\nvec2_norm_y(x :: float, y :: float) :: float\n```\nY component of normalised vector.",

	// ---- type conversion ----
	"to_int":   "```chasm\nto_int(v :: float) :: int\n```\nConvert float → int (truncates).",
	"to_float": "```chasm\nto_float(v :: int) :: float\n```\nConvert int → float.",
	"to_bool":  "```chasm\nto_bool(v :: int) :: bool\n```\nConvert int → bool (0 = false).",

	// ---- color ----
	"rgb":        "```chasm\nrgb(r :: int, g :: int, b :: int) :: int\n```\nPack RGB into `0xRRGGBBFF`.",
	"rgba":       "```chasm\nrgba(r :: int, g :: int, b :: int, a :: int) :: int\n```\nPack RGBA into `0xRRGGBBAA`.",
	"color_r":    "```chasm\ncolor_r(c :: int) :: int\n```\nExtract red channel.",
	"color_g":    "```chasm\ncolor_g(c :: int) :: int\n```\nExtract green channel.",
	"color_b":    "```chasm\ncolor_b(c :: int) :: int\n```\nExtract blue channel.",
	"color_a":    "```chasm\ncolor_a(c :: int) :: int\n```\nExtract alpha channel.",
	"color_lerp": "```chasm\ncolor_lerp(a :: int, b :: int, t :: float) :: int\n```\nInterpolate between two packed colors.",
	"color_mix":  "```chasm\ncolor_mix(a :: int, b :: int, t :: float) :: int\n```\nAlias for `color_lerp`.",

	// ---- bitwise ----
	"bit_and": "```chasm\nbit_and(a :: int, b :: int) :: int\n```\nBitwise AND.",
	"bit_or":  "```chasm\nbit_or(a :: int, b :: int) :: int\n```\nBitwise OR.",
	"bit_xor": "```chasm\nbit_xor(a :: int, b :: int) :: int\n```\nBitwise XOR.",
	"bit_not": "```chasm\nbit_not(v :: int) :: int\n```\nBitwise NOT.",
	"bit_shl": "```chasm\nbit_shl(v :: int, n :: int) :: int\n```\nShift left by `n` bits.",
	"bit_shr": "```chasm\nbit_shr(v :: int, n :: int) :: int\n```\nShift right by `n` bits.",

	// ---- strings ----
	"int_to_str":   "```chasm\nint_to_str(v :: int) :: string\n```\nInteger → string.",
	"float_to_str": "```chasm\nfloat_to_str(v :: float) :: string\n```\nFloat → string.",
	"bool_to_str":  "```chasm\nbool_to_str(v :: bool) :: string\n```\nBool → `\"true\"` or `\"false\"`.",
	"str_len":      "```chasm\nstr_len(s :: string) :: int\n```\nByte length of string.",
	"str_concat":   "```chasm\nstr_concat(a :: string, b :: string) :: string\n```\nConcatenate two strings.",
	"str_slice":    "```chasm\nstr_slice(s :: string, from :: int, to :: int) :: string\n```\nSubstring `[from, to)`.",
	"str_char_at":  "```chasm\nstr_char_at(s :: string, i :: int) :: int\n```\nByte value at index.",
	"str_contains": "```chasm\nstr_contains(s :: string, sub :: string) :: bool\n```\nSubstring check.",
	"str_upper":    "```chasm\nstr_upper(s :: string) :: string\n```\nUppercase copy.",
	"str_lower":    "```chasm\nstr_lower(s :: string) :: string\n```\nLowercase copy.",
	"str_trim":     "```chasm\nstr_trim(s :: string) :: string\n```\nStrip whitespace.",
	"str_eq":       "```chasm\nstr_eq(a :: string, b :: string) :: bool\n```\nString equality.",

	// ---- arrays ----
	"array_new":   "```chasm\narray_new(cap :: int) :: []int\n```\nCreate a heap-backed growable array.",
	"array_fixed": "```chasm\narray_fixed(cap :: int) :: []int\narray_fixed(cap :: int, default :: float) :: []float\n```\nCreate an arena-backed fixed-capacity array for `@attr` use.",

	// ---- i/o ----
	"print":     "```chasm\nprint(x) :: void\n```\nPrint a value followed by a newline.",
	"log":       "```chasm\nlog(x) :: void\n```\nAlias for `print`.",
	"assert":    "```chasm\nassert(cond :: bool) :: void\n```\nAbort if `cond` is false.",
	"assert_eq": "```chasm\nassert_eq(a :: int, b :: int) :: void\n```\nAbort if `a != b`.",
	"todo":      "```chasm\ntodo() :: void\n```\nMark a code path as unreachable (aborts).",

	// ---- random ----
	"rand":       "```chasm\nrand() :: float\n```\nRandom float in `[0, 1)`.",
	"rand_range": "```chasm\nrand_range(lo :: float, hi :: float) :: float\n```\nRandom float in `[lo, hi)`.",
	"rand_int":   "```chasm\nrand_int(lo :: int, hi :: int) :: int\n```\nRandom int in `[lo, hi)`.",

	// ---- time ----
	"time_now": "```chasm\ntime_now() :: float\n```\nCurrent time as seconds since epoch.",
	"time_ms":  "```chasm\ntime_ms() :: int\n```\nCurrent time in milliseconds.",
}

// keywordItems returns completion items for all Chasm keywords.
func keywordItems() []CompletionItem {
	keywords := []struct {
		label  string
		insert string
		detail string
	}{
		{"def", "def $1($2) :: $3 do\n  $0\nend", "declare a public function"},
		{"defp", "defp $1($2) :: $3 do\n  $0\nend", "declare a private function"},
		{"defstruct", "defstruct $1 do\n  $0\nend", "declare a struct type"},
		{"enum", "enum $1 { $0 }", "declare an enum type"},
		{"if", "if $1 do\n  $0\nend", "conditional branch"},
		{"if...else", "if $1 do\n  $2\nelse\n  $0\nend", "conditional with else"},
		{"while", "while $1 do\n  $0\nend", "conditional loop"},
		{"for", "for $1 in $2..$3 do\n  $0\nend", "range iteration"},
		{"for...in", "for $1 in $2 do\n  $0\nend", "array iteration"},
		{"case", "case $1 do\n  when $2 -> $3\n  _ -> $0\nend", "pattern match"},
		{"return", "return $0", "return a value"},
		{"break", "break", "exit loop"},
		{"continue", "continue", "next iteration"},
		{"import", "import \"$0\"", "import a file"},
		{"true", "true", "boolean true"},
		{"false", "false", "boolean false"},
		{"and", "and", "logical AND"},
		{"or", "or", "logical OR"},
		{"not", "not ", "logical NOT"},
		{"frame", "frame", "frame lifetime"},
		{"script", "script", "script lifetime"},
		{"persistent", "persistent", "persistent lifetime"},
		{"copy_to_script", "copy_to_script($0)", "promote to script lifetime"},
		{"persist_copy", "persist_copy($0)", "promote to persistent lifetime"},
		{"array_fixed", "array_fixed($1, $0)", "arena-backed fixed array"},
		{"array_new", "array_new($0)", "heap-backed growable array"},
	}
	var items []CompletionItem
	for _, kw := range keywords {
		items = append(items, CompletionItem{
			Label:            kw.label,
			Kind:             CIKKeyword,
			Detail:           kw.detail,
			InsertText:       kw.insert,
			InsertTextFormat: 2,
		})
	}
	return items
}

// builtinItems returns completion items for all builtin functions.
func builtinItems() []CompletionItem {
	builtins := []struct {
		name   string
		insert string
		detail string
	}{
		// math
		{"abs", "abs($0)", "float → float"},
		{"sqrt", "sqrt($0)", "float → float"},
		{"pow", "pow($1, $0)", "b^e"},
		{"sin", "sin($0)", "sine (radians)"},
		{"cos", "cos($0)", "cosine (radians)"},
		{"tan", "tan($0)", "tangent (radians)"},
		{"atan2", "atan2($1, $0)", "atan2(y, x)"},
		{"floor", "floor($0)", "round down"},
		{"ceil", "ceil($0)", "round up"},
		{"round", "round($0)", "round to nearest"},
		{"fract", "fract($0)", "fractional part"},
		{"sign", "sign($0)", "-1, 0, or 1"},
		{"min", "min($1, $0)", "minimum"},
		{"max", "max($1, $0)", "maximum"},
		{"clamp", "clamp($1, $2, $0)", "clamp(v, lo, hi)"},
		{"lerp", "lerp($1, $2, $0)", "linear interpolation"},
		{"scale", "scale($1, $0)", "multiply by factor"},
		{"wrap", "wrap($1, $2, $0)", "wrap into range"},
		{"snap", "snap($1, $0)", "round to step"},
		{"smooth_step", "smooth_step($1, $2, $0)", "smooth Hermite"},
		{"move_toward", "move_toward($1, $2, $0)", "move toward target"},
		{"angle_diff", "angle_diff($1, $0)", "shortest angle diff"},
		{"deg_to_rad", "deg_to_rad($0)", "degrees → radians"},
		{"rad_to_deg", "rad_to_deg($0)", "radians → degrees"},
		{"ping_pong", "ping_pong($1, $0)", "bounce over range"},
		// vec2
		{"vec2_len", "vec2_len($1, $0)", "vector length"},
		{"vec2_dot", "vec2_dot($1, $2, $3, $0)", "dot product"},
		{"vec2_dist", "vec2_dist($1, $2, $3, $0)", "distance"},
		{"vec2_angle", "vec2_angle($1, $0)", "vector angle"},
		{"vec2_norm_x", "vec2_norm_x($1, $0)", "normalised x"},
		{"vec2_norm_y", "vec2_norm_y($1, $0)", "normalised y"},
		// conversion
		{"to_int", "to_int($0)", "float → int"},
		{"to_float", "to_float($0)", "int → float"},
		{"to_bool", "to_bool($0)", "int → bool"},
		// color
		{"rgb", "rgb($1, $2, $0)", "pack RGB"},
		{"rgba", "rgba($1, $2, $3, $0)", "pack RGBA"},
		{"color_r", "color_r($0)", "red channel"},
		{"color_g", "color_g($0)", "green channel"},
		{"color_b", "color_b($0)", "blue channel"},
		{"color_a", "color_a($0)", "alpha channel"},
		{"color_lerp", "color_lerp($1, $2, $0)", "interpolate colors"},
		// bitwise
		{"bit_and", "bit_and($1, $0)", "bitwise AND"},
		{"bit_or", "bit_or($1, $0)", "bitwise OR"},
		{"bit_xor", "bit_xor($1, $0)", "bitwise XOR"},
		{"bit_not", "bit_not($0)", "bitwise NOT"},
		{"bit_shl", "bit_shl($1, $0)", "shift left"},
		{"bit_shr", "bit_shr($1, $0)", "shift right"},
		// strings
		{"int_to_str", "int_to_str($0)", "int → string"},
		{"float_to_str", "float_to_str($0)", "float → string"},
		{"bool_to_str", "bool_to_str($0)", "bool → string"},
		{"str_len", "str_len($0)", "string length"},
		{"str_concat", "str_concat($1, $0)", "concatenate"},
		{"str_slice", "str_slice($1, $2, $0)", "substring"},
		{"str_char_at", "str_char_at($1, $0)", "byte at index"},
		// i/o
		{"print", "print($0)", "print value"},
		{"log", "log($0)", "log value"},
		{"assert", "assert($0)", "assert condition"},
		{"todo", "todo()", "unreachable"},
		// random
		{"rand", "rand()", "random [0,1)"},
		{"rand_range", "rand_range($1, $0)", "random in range"},
		{"rand_int", "rand_int($1, $0)", "random int"},
		// time
		{"time_now", "time_now()", "current time (s)"},
		{"time_ms", "time_ms()", "current time (ms)"},
	}
	var items []CompletionItem
	for _, b := range builtins {
		items = append(items, CompletionItem{
			Label:            b.name,
			Kind:             CIKFunction,
			Detail:           b.detail,
			InsertText:       b.insert,
			InsertTextFormat: 2,
		})
	}
	return items
}

// methodItems returns completion items for array/string methods.
func methodItems() []CompletionItem {
	methods := []struct {
		name   string
		insert string
		detail string
	}{
		{"len", "len", "number of elements"},
		{"push", "push($0)", "append element"},
		{"get", "get($0)", "read element at index"},
		{"set", "set($1, $0)", "write element at index"},
		{"pop", "pop()", "remove and return last"},
		{"clear", "clear()", "reset length to 0"},
	}
	var items []CompletionItem
	for _, m := range methods {
		items = append(items, CompletionItem{
			Label:            m.name,
			Kind:             CIKMethod,
			Detail:           m.detail,
			InsertText:       m.insert,
			InsertTextFormat: 2,
		})
	}
	return items
}

// atomItems returns common atom completions.
func atomItems() []CompletionItem {
	atoms := []string{"idle", "running", "dead", "active", "inactive", "normal", "paused"}
	var items []CompletionItem
	for _, a := range atoms {
		items = append(items, CompletionItem{
			Label: ":" + a,
			Kind:  CIKEnumMember,
		})
	}
	return items
}
