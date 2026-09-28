/*
 * Manifest validation and C/D probe generation.
 *
 * Produces compiler-backed layout, scalar, declaration, and call checks without
 * reimplementing either language's type system or ABI layout rules.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module probes;

import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue;
import std.string : strip;

/*
 * Passive C/D measurements share indexes and labels. An empty expected value
 * requests equality; a nonempty value also requires that specific result.
 * Explicit call checks use a separate program and their own index sequence.
 */
struct Probe
{
    string cSource;
    string dSource;
    string cSupportSource;
    string dCallSource;

    string[] labels;
    string[] expectedValues;
    string[] callLabels;
}

void objectKeys(JSONValue value, string[] allowed, string context)
{
    enforce(value.type == JSONType.object, context ~ " must be an object");

    foreach (key, item; value.object)
    {
        enforce(allowed.canFind(key), context ~ ": unknown key '" ~ key ~ "'");
    }
}

string text(JSONValue value, string context, bool nonempty = true)
{
    enforce(value.type == JSONType.string, context ~ " must be a string");

    auto result = value.str;

    enforce(!result.canFind('\0'), context ~ " must not contain NUL");
    enforce(!nonempty || result.strip.length != 0, context ~ " must not be empty");

    return result;
}

string requiredText(JSONValue value, string key, string context)
{
    auto item = key in value.object;

    enforce(item !is null, context ~ ": missing '" ~ key ~ "'");

    return text(*item, context ~ "." ~ key);
}

JSONValue[] arrayValue(JSONValue value, string key, bool required = false)
{
    auto item = key in value.object;

    if (item is null)
    {
        enforce(!required, "manifest: missing '" ~ key ~ "'");

        return null;
    }

    enforce(item.type == JSONType.array, key ~ " must be an array");

    return item.array;
}

string[] strings(JSONValue manifest, string key, bool required = false)
{
    string[] result;

    foreach (item; arrayValue(manifest, key, required))
    {
        result ~= text(item, key, key != "cFlags" && key != "dFlags");
    }

    return result;
}

private string rowPrefix(size_t index)
{
    return "dabiprobe\\t" ~ to!string(index) ~ "\\t";
}

private void measurement(ref Probe probe, string label, string cExpression,
        string dExpression, string expected = "")
{
    auto prefix = rowPrefix(probe.labels.length);

    probe.labels ~= label;
    probe.expectedValues ~= expected;

    probe.cSource ~= "    printf(\"" ~ prefix ~ "%zu\\n\", (size_t)(" ~ cExpression ~ "));\n";
    probe.dSource ~= "    writeln(\"" ~ prefix ~ "\", " ~ dExpression ~ ");\n";
}

/*
 * Let the compilers classify scalar types instead of maintaining C spelling
 * rules here. Category zero is opaque: it does not establish equivalence of
 * pointees, array elements, aggregate members, or nested callback signatures.
 */
private void semantics(ref Probe probe, string label, string cExpression, string dType)
{
    measurement(probe, label ~ " scalar kind",
            "_Generic((" ~ cExpression ~ ")," ~ " _Bool: 1, char: (CHAR_MIN < 0 ? 2 : 3),"
            ~ " signed char: 2, unsigned char: 3," ~ " short: 2, unsigned short: 3,"
            ~ " int: 2, unsigned int: 3," ~ " long: 2, unsigned long: 3,"
            ~ " long long: 2, unsigned long long: 3," ~ " float: 4, double: 4, long double: 4, default: 0)",
            "dabiprobeScalarKind!(" ~ dType ~ ")");
}

private void typeMeasurements(ref Probe probe, string label, string cType, string dType)
{
    measurement(probe, label ~ " sizeof", "sizeof(" ~ cType ~ ")", "(" ~ dType ~ ").sizeof");
    measurement(probe, label ~ " alignof", "_Alignof(" ~ cType ~ ")", "(" ~ dType ~ ").alignof");

    semantics(probe, label, "(" ~ cType ~ "){0}", dType);
}

Probe generate(JSONValue manifest)
{
    /*
     * Validate the manifest's shape, not a home-grown subset of C or D syntax.
     * Expressions and source fragments remain trusted compiler input; unknown
     * keys are errors so a misspelled check cannot disappear silently.
     */
    objectKeys(manifest, [
        "headers", "imports", "cFlags", "dFlags", "types", "constants",
        "functions", "cSource", "dSource", "calls"
    ], "manifest");

    auto headers = strings(manifest, "headers", true);
    auto imports = strings(manifest, "imports", true);
    auto types = arrayValue(manifest, "types");
    auto constants = arrayValue(manifest, "constants");
    auto functions = arrayValue(manifest, "functions");
    auto calls = arrayValue(manifest, "calls");

    enforce(types.length + constants.length + functions.length + calls.length != 0,
            "manifest must select at least one type, constant, function or call");

    Probe probe;

    probe.cSource = "#include <stdio.h>\n" ~ "#include <stddef.h>\n"
        ~ "#include <stdint.h>\n" ~ "#include <inttypes.h>\n" ~ "#include <limits.h>\n";

    probe.dSource = q{
        import std.stdio : writeln;
        import std.traits : isIntegral, isSomeChar, isUnsigned, isFloatingPoint,
            OriginalType, Unqual, isStaticArray;

        template dabiprobeScalarKind(T)
        {
            alias Base = Unqual!(OriginalType!T);

            static if (is(Base == bool))
            {
                enum dabiprobeScalarKind = 1;
            }
            else static if (isIntegral!Base || isSomeChar!Base)
            {
                enum dabiprobeScalarKind = isUnsigned!Base || isSomeChar!Base ? 3 : 2;
            }
            else static if (isFloatingPoint!Base)
            {
                enum dabiprobeScalarKind = 4;
            }
            else
            {
                enum dabiprobeScalarKind = 0;
            }
        }
    };

    foreach (header; headers)
    {
        enforce(!header.canFind('"') && !header.canFind('\n')
                && !header.canFind('\r'), "header paths must not contain quotes or newlines");

        probe.cSource ~= "#include \"" ~ header ~ "\"\n";
    }

    foreach (moduleName; imports)
    {
        probe.dSource ~= "import " ~ moduleName ~ ";\n";
    }

    /*
     * Preserve the shared includes and declarations before adding either main.
     * The support object and later call program need the same build context.
     */
    if (auto source = "cSource" in manifest.object)
    {
        probe.cSupportSource = probe.cSource ~ text(*source, "cSource", false) ~ "\n";
    }

    if (auto source = "dSource" in manifest.object)
    {
        probe.dSource ~= text(*source, "dSource", false) ~ "\n";
    }

    auto dPreamble = probe.dSource;

    probe.cSource ~= "int main(void) {\n";
    probe.dSource ~= "void main() {\n";

    measurement(probe, "baseline pointer.sizeof", "sizeof(void*)", "(void*).sizeof");

    auto endianPrefix = rowPrefix(probe.labels.length);

    probe.labels ~= "baseline endianness";
    probe.expectedValues ~= "";

    probe.cSource ~= "    uint16_t dabiprobe_endian = 1;\n";
    probe.cSource ~= "    printf(\"" ~ endianPrefix
        ~ "%s\\n\", *(unsigned char*)&dabiprobe_endian ? \"little\" : \"big\");\n";
    probe.dSource ~= "    version (LittleEndian) writeln(\"" ~ endianPrefix
        ~ "little\");\n" ~ "    else writeln(\"" ~ endianPrefix ~ "big\");\n";

    foreach (type; types)
    {
        objectKeys(type, ["c", "d", "fields"], "type");

        auto cType = requiredText(type, "c", "type");
        auto dType = requiredText(type, "d", "type");
        auto label = cType ~ " <-> " ~ dType;

        typeMeasurements(probe, label, cType, dType);

        foreach (field; arrayValue(type, "fields"))
        {
            string cField;
            string dField;

            if (field.type == JSONType.string)
            {
                cField = dField = text(field, "field");
            }
            else
            {
                objectKeys(field, ["c", "d"], "field");

                cField = requiredText(field, "c", "field");
                dField = requiredText(field, "d", "field");
            }

            auto fieldLabel = label ~ " field " ~ cField ~ " <-> " ~ dField;
            auto cExpression = "((" ~ cType ~ "*)0)->" ~ cField;
            auto dExpression = dType ~ "." ~ dField;

            measurement(probe, fieldLabel ~ " offsetof",
                    "offsetof(" ~ cType ~ ", " ~ cField ~ ")", dExpression ~ ".offsetof");
            measurement(probe, fieldLabel ~ " sizeof",
                    "sizeof(" ~ cExpression ~ ")", dExpression ~ ".sizeof");
            semantics(probe, fieldLabel, cExpression, "typeof(" ~ dExpression ~ ")");
        }
    }

    /*
     * Keep negative values distinct from the full unsigned 64-bit range. C's
     * _Generic inspects the type without evaluating the expression or producing
     * unsigned-comparison warnings. D stores the value before choosing a format
     * so even a stateful integral expression is evaluated exactly once.
     */
    foreach (constant; constants)
    {
        objectKeys(constant, ["c", "d"], "constant");

        auto cExpression = "(" ~ requiredText(constant, "c", "constant") ~ ")";
        auto dExpression = "(" ~ requiredText(constant, "d", "constant") ~ ")";
        auto prefix = rowPrefix(probe.labels.length);

        probe.labels ~= "constant " ~ cExpression ~ " <-> " ~ dExpression;
        probe.expectedValues ~= "";

        probe.cSource ~= "    _Static_assert(_Generic(" ~ cExpression
            ~ ", _Bool: 1, char: 1, signed char: 1, unsigned char: 1, short: 1, unsigned short: 1,"
            ~ " int: 1, unsigned int: 1, long: 1, unsigned long: 1, long long: 1, unsigned long long: 1,"
            ~ " default: 0), \"constant must be integral\");\n";
        probe.cSource ~= "    _Static_assert(sizeof(" ~ cExpression
            ~ ") <= 8, \"constant must fit 64 bits\");\n";

        probe.cSource ~= "    if (_Generic(" ~ cExpression
            ~ ", char: (CHAR_MIN < 0), signed char: 1, short: 1, int: 1, long: 1, long long: 1, default: 0))\n"
            ~ "        printf(\"" ~ prefix ~ "%\" PRIdMAX \"\\n\", (intmax_t)" ~ cExpression
            ~ ");\n";
        probe.cSource ~= "    else printf(\"" ~ prefix
            ~ "%\" PRIuMAX \"\\n\", (uintmax_t)" ~ cExpression ~ ");\n";

        probe.dSource ~= "    {\n";
        probe.dSource ~= "        alias dabiprobeConstantType = OriginalType!(typeof("
            ~ dExpression ~ "));\n";
        probe.dSource ~= "        static assert(isIntegral!dabiprobeConstantType"
            ~ " || isSomeChar!dabiprobeConstantType || is(dabiprobeConstantType == bool),"
            ~ " \"constant must be integral\");\n";
        probe.dSource ~= "        static assert(dabiprobeConstantType.sizeof <= 8,"
            ~ " \"constant must fit 64 bits\");\n\n";

        probe.dSource ~= "        const dabiprobeConstantValue = " ~ dExpression ~ ";\n\n";
        probe.dSource ~= "        if (dabiprobeConstantValue < 0)\n"
            ~ "            writeln(\"" ~ prefix ~ "\", cast(long)dabiprobeConstantValue);\n";
        probe.dSource ~= "        else\n" ~ "            writeln(\"" ~ prefix
            ~ "\", cast(ulong)dabiprobeConstantValue);\n";
        probe.dSource ~= "    }\n";
    }

    /*
     * Check each real declaration against its supplied signature, then compare
     * the paired parameter and return measurements across languages. Neither
     * check calls the function. Named aliases keep complex type spelling in
     * the compiler, rather than requiring a declaration parser in this tool.
     */
    foreach (index, functionEntry; functions)
    {
        objectKeys(functionEntry, [
            "c", "d", "returns", "parameters", "variadic"
        ], "function");

        auto cFunction = requiredText(functionEntry, "c", "function");
        auto dFunction = requiredText(functionEntry, "d", "function");
        auto returnValue = "returns" in functionEntry.object;

        enforce(returnValue !is null, "function: missing 'returns'");
        objectKeys(*returnValue, ["c", "d"], "function.returns");

        auto cReturn = requiredText(*returnValue, "c", "function.returns");
        auto dReturn = requiredText(*returnValue, "d", "function.returns");
        auto parameters = arrayValue(functionEntry, "parameters", true);

        bool variadic;

        if (auto flag = "variadic" in functionEntry.object)
        {
            enforce(flag.type == JSONType.true_ || flag.type == JSONType.false_,
                    "function.variadic must be a boolean");

            variadic = flag.type == JSONType.true_;
        }

        enforce(!variadic || parameters.length != 0,
                "variadic functions require at least one named parameter");

        auto label = "function " ~ cFunction ~ " <-> " ~ dFunction;
        auto typeName = "dabiprobe_function_" ~ to!string(index);

        probe.cSource ~= "    typedef " ~ cReturn ~ " " ~ typeName ~ "_return;\n";
        probe.dSource ~= "    alias " ~ typeName ~ "_return = " ~ dReturn ~ ";\n";

        string[] parameterNames;

        foreach (parameterIndex, parameter; parameters)
        {
            objectKeys(parameter, ["c", "d"], "function parameter");

            auto cType = requiredText(parameter, "c", "function parameter");
            auto dType = requiredText(parameter, "d", "function parameter");

            enforce(cType.strip != "void" && dType.strip != "void",
                    "void parameter is not supported; use an empty parameters array");

            auto name = typeName ~ "_parameter_" ~ to!string(parameterIndex);

            parameterNames ~= name;

            probe.cSource ~= "    typedef " ~ cType ~ " " ~ name ~ ";\n";
            probe.dSource ~= "    alias " ~ name ~ " = " ~ dType ~ ";\n";

            /* C array parameters decay to pointers; D static arrays do not. */
            probe.dSource ~= "    static assert(!isStaticArray!" ~ name
                ~ ", \"D static array function parameters require an explicit pointer contract\");\n";

            typeMeasurements(probe, label ~ " parameter " ~ to!string(parameterIndex), name, name);
        }

        /* Literal void needs no layout probe and cannot be used with sizeof. */
        bool cVoid = cReturn.strip == "void";
        bool dVoid = dReturn.strip == "void";

        if (cVoid != dVoid)
        {
            measurement(probe, label ~ " return void", cVoid ? "1" : "0", dVoid ? "1" : "0");
        }
        else if (!cVoid)
        {
            typeMeasurements(probe, label ~ " return", typeName ~ "_return", typeName ~ "_return");
        }

        auto cParameters = parameterNames.length == 0 ? "void" : parameterNames.join(", ");
        auto dParameters = parameterNames.join(", ");

        if (variadic)
        {
            cParameters ~= ", ...";
            dParameters ~= ", ...";
        }

        probe.cSource ~= "    typedef " ~ typeName ~ "_return (*" ~ typeName
            ~ ")(" ~ cParameters ~ ");\n";
        probe.dSource ~= "    alias " ~ typeName ~ " = extern(C) " ~ typeName
            ~ "_return function(" ~ dParameters ~ ");\n";
        probe.dSource ~= "    alias " ~ typeName ~ "_actual = typeof(&" ~ dFunction ~ ");\n";

        /*
         * Implicit conversion accepts stronger D attributes (nothrow, @nogc)
         * without erasing ABI-relevant linkage, ref parameters, or variadics.
         */
        measurement(probe, label ~ " declaration", "_Generic((&" ~ cFunction ~ "), " ~ typeName ~ ": 1, default: 0)",
                "(is(" ~ typeName ~ "_actual : " ~ typeName ~ ") ? 1 : 0)", "1");
    }

    /*
     * A separate main lets the caller delay explicit interop tests until all
     * passive checks pass. Require bool instead of treating arbitrary integers
     * or pointers as successful assertions; typeof does not execute the call.
     */
    if (calls.length != 0)
    {
        probe.dCallSource = dPreamble ~ "void main() {\n";
    }

    foreach (call; calls)
    {
        objectKeys(call, ["name", "d"], "call");

        auto name = requiredText(call, "name", "call");
        auto expression = requiredText(call, "d", "call");

        probe.dCallSource ~= "    static assert(is(typeof((" ~ expression
            ~ ")) == bool)," ~ " \"call expression must have bool type\");\n";

        auto prefix = rowPrefix(probe.callLabels.length);

        probe.callLabels ~= name;
        probe.dCallSource ~= "    writeln(\"" ~ prefix ~ "\", ((" ~ expression ~ ") ? 1 : 0));\n";
    }

    if (calls.length != 0)
    {
        probe.dCallSource ~= "}\n";
    }

    probe.cSource ~= "    return 0;\n}\n";
    probe.dSource ~= "}\n";

    return probe;
}
