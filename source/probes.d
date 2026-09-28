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
import std.string : replace, strip;

struct CheckMetadata
{
    string declaration;
    string property;
    string kind;
    string policy;
    string cExpression;
    string dType;
    string unsupportedValue;
    string unsupportedReason;
}

struct PendingCheck
{
    CheckMetadata check;
    string status;
    string reason;
}

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

    CheckMetadata[] checks;
    CheckMetadata[] callChecks;
    PendingCheck[] pendingChecks;
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
        string dExpression, string expected = "", CheckMetadata check = CheckMetadata.init)
{
    auto prefix = rowPrefix(probe.labels.length);

    probe.labels ~= label;
    probe.expectedValues ~= expected;
    probe.checks ~= check;

    probe.cSource ~= "    printf(\"" ~ prefix ~ "%zu\\n\", (size_t)(" ~ cExpression ~ "));\n";
    probe.dSource ~= "    writeln(\"" ~ prefix ~ "\", " ~ dExpression ~ ");\n";
}

void validateManifest(JSONValue manifest)
{
    objectKeys(manifest, [
        "headers", "imports", "cFlags", "dFlags", "types", "constants",
        "functions", "cSource", "dSource", "calls"
    ], "manifest");

    strings(manifest, "headers", true);
    strings(manifest, "imports", true);
    strings(manifest, "cFlags");
    strings(manifest, "dFlags");

    foreach (entry; arrayValue(manifest, "types"))
    {
        objectKeys(entry, ["c", "d", "fields", "opaque"], "type");
        requiredText(entry, "c", "type");
        requiredText(entry, "d", "type");

        if (auto opaque = "opaque" in entry.object)
        {
            enforce(opaque.type == JSONType.true_
                    || opaque.type == JSONType.false_, "type.opaque must be a boolean");
            enforce(opaque.type != JSONType.true_ || !("fields" in entry.object),
                    "opaque types cannot select fields");
        }

        if (auto fields = "fields" in entry.object)
        {
            enforce(fields.type == JSONType.array || (fields.type == JSONType.string
                    && fields.str == "*"), "type.fields must be an array or '*'");

            if (fields.type == JSONType.array)
            {
                foreach (field; fields.array)
                {
                    if (field.type == JSONType.string)
                    {
                        text(field, "field");
                    }
                    else
                    {
                        objectKeys(field, ["c", "d"], "field");
                        requiredText(field, "c", "field");
                        requiredText(field, "d", "field");
                    }
                }
            }
        }
    }

    foreach (entry; arrayValue(manifest, "functions"))
    {
        objectKeys(entry, ["c", "d", "returns", "parameters", "variadic"], "function");
        requiredText(entry, "c", "function");
        requiredText(entry, "d", "function");

        bool hasReturn = ("returns" in entry.object) !is null;
        bool hasParameters = ("parameters" in entry.object) !is null;

        enforce(hasReturn == hasParameters,
                "function requires both 'returns' and 'parameters', or neither for inference");

        if (hasReturn)
        {
            objectKeys(entry["returns"], ["c", "d"], "function.returns");
            requiredText(entry["returns"], "c", "function.returns");
            requiredText(entry["returns"], "d", "function.returns");

            foreach (parameter; arrayValue(entry, "parameters", true))
            {
                objectKeys(parameter, ["c", "d"], "function parameter");
                requiredText(parameter, "c", "function parameter");
                requiredText(parameter, "d", "function parameter");
            }
        }

        if (auto flag = "variadic" in entry.object)
        {
            enforce(hasReturn, "function.variadic requires an explicit signature");
            enforce(flag.type == JSONType.true_ || flag.type == JSONType.false_,
                    "function.variadic must be a boolean");
        }
    }

    foreach (key; ["constants", "calls"])
    {
        foreach (entry; arrayValue(manifest, key))
        {
            auto cKey = key == "calls" ? "name" : "c";

            objectKeys(entry, [cKey, "d"], key);
            requiredText(entry, cKey, key);
            requiredText(entry, "d", key);
        }
    }

    foreach (key; ["cSource", "dSource"])
    {
        if (auto source = key in manifest.object)
        {
            text(*source, key, false);
        }
    }
}

private struct Candidate
{
    string type;
    string condition;
    string[] arityVariants;
}

private struct Alternatives
{
    Candidate[] values;
    string reason;
}

/*
 * C11 cannot decompose arbitrary function pointer types. Build only complete,
 * bounded candidates, then let _Generic check each native C declaration.
 * D's target model prunes impossible integer spellings; independent C layout
 * predicates still guard every surviving choice. No candidate is a cast.
 * Each arity variant adds int at one callable node. C acceptance of both the
 * original and altered signatures demonstrates an incomplete prototype.
 */
private struct RepresentationMatcher
{
    JSONValue reflection;
    JSONValue[] types;
    string declarations;
    size_t nextType;

    private string define(string pattern)
    {
        auto name = "dabiprobe_rep_" ~ to!string(nextType++);

        declarations ~= "    typedef " ~ pattern.replace("@", name) ~ ";\n";

        return name;
    }

    private string layout(JSONValue node, string cType)
    {
        return "sizeof(" ~ cType ~ ") == " ~ to!string(
                node["size"].integer) ~ " && _Alignof(" ~ cType ~ ") == " ~ to!string(
                node["align"].integer);
    }

    private bool isOpaque(JSONValue node)
    {
        auto mapping = node["mapping"].integer;

        if (mapping < 0)
        {
            return false;
        }

        auto flag = "opaque" in types[cast(size_t) mapping].object;

        return flag !is null && flag.type == JSONType.true_;
    }

    Alternatives explicitCandidates(string returnType, string[] parameterTypes,
            bool variadic, JSONValue contract)
    {
        string signature(string resultType, string[] parameters)
        {
            auto arguments = parameters.length ? parameters.join(", ") : "void";

            if (variadic)
            {
                arguments ~= ", ...";
            }

            return define(resultType ~ " (*@)(" ~ arguments ~ ")");
        }

        Alternatives result;
        auto normal = signature(returnType, parameterTypes);
        auto extra = signature(returnType, parameterTypes ~ ["int"]);

        result.values ~= Candidate(normal, "1", [extra]);

        if (contract.type != JSONType.object)
        {
            return result;
        }

        auto nodes = [contract["returns"]] ~ contract["parameters"].array;
        size_t projectionCount = 2;

        foreach (index, node; nodes)
        {
            auto choices = candidates(node);

            if (choices.reason.length)
            {
                return choices;
            }

            foreach (choice; choices.values)
            {
                if (choice.arityVariants.length == 0)
                {
                    continue;
                }

                projectionCount += 1 + choice.arityVariants.length;

                if (projectionCount > 256)
                {
                    return Alternatives(null,
                            "signature exceeds the limit of 256 complete C type candidates including prototype checks");
                }

                auto projectedParameters = parameterTypes.dup;
                auto projectedReturn = returnType;

                if (index == 0)
                {
                    projectedReturn = choice.type;
                }
                else
                {
                    projectedParameters[index - 1] = choice.type;
                }

                auto projected = signature(projectedReturn, projectedParameters);
                string[] variants;

                foreach (variantType; choice.arityVariants)
                {
                    if (index == 0)
                    {
                        projectedReturn = variantType;
                    }
                    else
                    {
                        projectedParameters[index - 1] = variantType;
                    }

                    variants ~= signature(projectedReturn, projectedParameters);
                }

                result.values ~= Candidate(projected, "1", variants);
            }
        }

        return result;
    }

    Alternatives candidates(JSONValue node, bool pointee = false)
    {
        if (node.type != JSONType.object)
        {
            return Alternatives(null, "compiler reflection is required for representation checks");
        }

        if (auto reason = "reason" in node.object)
        {
            return Alternatives(null, reason.str);
        }

        auto kind = node["kind"].str;
        auto qualifier = node["qualifier"].str.length ? " const" : "";
        Alternatives result;

        if (kind == "void")
        {
            result.values ~= Candidate("void" ~ qualifier, "1");
        }
        else if (kind == "signed" || kind == "unsigned")
        {
            foreach (integer; reflection["integers"].array)
            {
                if (integer["size"] != node["size"] || integer["align"] != node["align"])
                {
                    continue;
                }

                auto spelling = integer["c"].str;

                if (kind == "unsigned")
                {
                    spelling = spelling == "signed char" ? "unsigned char" : "unsigned " ~ spelling;
                }

                result.values ~= Candidate(spelling ~ qualifier, layout(node, spelling));
            }
        }
        else if (kind == "bool" || kind == "char" || kind == "float")
        {
            auto spelling = kind == "bool" ? "_Bool" : kind == "char" ? "char" : node["format"].str;
            auto condition = layout(node, spelling);

            if (kind == "float")
            {
                auto prefix = spelling == "float" ? "FLT" : spelling == "double" ? "DBL" : "LDBL";

                condition ~= " && " ~ prefix ~ "_MANT_DIG == " ~ to!string(
                        node["digits"].integer) ~ " && " ~ prefix ~ "_MAX_EXP == " ~ to!string(
                        node["maxExponent"].integer);
            }

            result.values ~= Candidate(spelling ~ qualifier, condition);
        }
        else if (kind == "aggregate")
        {
            auto mapping = node["mapping"].integer;

            if (mapping < 0)
            {
                return Alternatives(null,
                        "aggregate requires a selected C/D type mapping: " ~ node["name"].str);
            }

            auto spelling = requiredText(types[cast(size_t) mapping], "c", "type");

            if (isOpaque(node))
            {
                if (!pointee)
                {
                    return Alternatives(null,
                            "opaque aggregate mappings support pointer contracts only, not by-value use: "
                            ~ node["name"].str);
                }

                return Alternatives([Candidate(spelling ~ qualifier, "1")]);
            }

            if (node["complete"].type != JSONType.true_)
            {
                return Alternatives(null,
                        "incomplete aggregate requires an explicit opaque:true type mapping: "
                        ~ node["name"].str);
            }

            result.values ~= Candidate(spelling ~ qualifier, layout(node, spelling));
        }
        else if (kind == "pointer" || kind == "array")
        {
            if (kind == "array" && node["length"].integer == 0)
            {
                return Alternatives(null, "zero-length arrays are not standard C types");
            }

            auto child = candidates(node["element"], kind == "pointer");

            if (child.reason.length)
            {
                return child;
            }

            foreach (candidate; child.values)
            {
                auto declarator = kind == "pointer" ? " *" ~ qualifier ~ " @" : qualifier ~ " @[" ~ to!string(
                        node["length"].integer) ~ "]";
                auto name = define(candidate.type ~ declarator);
                string[] variants;

                foreach (variantType; candidate.arityVariants)
                {
                    variants ~= define(variantType ~ declarator);
                }

                result.values ~= Candidate(name,
                        "(" ~ candidate.condition ~ ") && " ~ layout(node, name), variants);
            }
        }
        else if (kind == "function")
        {
            auto returns = candidates(node["returns"]);

            if (returns.reason.length)
            {
                return returns;
            }

            Candidate[] combinations = [Candidate("", "1")];

            foreach (parameter; node["parameters"].array)
            {
                auto choices = candidates(parameter);

                if (choices.reason.length)
                {
                    return choices;
                }

                if (combinations.length * choices.values.length * returns.values.length > 256)
                {
                    return Alternatives(null,
                            "signature exceeds the limit of 256 complete C type candidates");
                }

                Candidate[] next;
                size_t projectionCount;

                foreach (combination; combinations)
                {
                    foreach (choice; choices.values)
                    {
                        projectionCount += 1 + combination.arityVariants.length
                            + choice.arityVariants.length;

                        if (projectionCount * returns.values.length > 256)
                        {
                            return Alternatives(null, "signature exceeds the limit of 256 complete C type candidates including prototype checks");
                        }

                        auto separator = combination.type.length ? ", " : "";
                        string[] variants;

                        foreach (variantType; combination.arityVariants)
                        {
                            variants ~= variantType ~ separator ~ choice.type;
                        }

                        foreach (variantType; choice.arityVariants)
                        {
                            variants ~= combination.type ~ separator ~ variantType;
                        }

                        next ~= Candidate(combination.type ~ separator ~ choice.type,
                                "(" ~ combination.condition ~ ") && (" ~ choice.condition ~ ")",
                                variants);
                    }
                }

                combinations = next;
            }

            size_t projectionCount;

            foreach (returnsCandidate; returns.values)
            {
                foreach (combination; combinations)
                {
                    projectionCount += 2 + returnsCandidate.arityVariants.length
                        + combination.arityVariants.length;

                    if (projectionCount > 256)
                    {
                        return Alternatives(null,
                                "signature exceeds the limit of 256 complete C type candidates including prototype checks");
                    }

                    auto parameters = combination.type.length ? combination.type : "void";
                    auto declarator = " (*" ~ qualifier ~ " @)(";
                    auto name = define(returnsCandidate.type ~ declarator ~ parameters ~ ")");
                    auto linkage = node["linkage"].str == "C" ? "1" : "0";
                    auto extraParameters = combination.type.length
                        ? combination.type ~ ", int" : "int";
                    string[] variants = [
                        define(returnsCandidate.type ~ declarator ~ extraParameters ~ ")")
                    ];

                    foreach (variantType; returnsCandidate.arityVariants)
                    {
                        variants ~= define(variantType ~ declarator ~ parameters ~ ")");
                    }

                    foreach (variantType; combination.arityVariants)
                    {
                        variants ~= define(returnsCandidate.type ~ declarator ~ variantType ~ ")");
                    }

                    result.values ~= Candidate(name,
                            "(" ~ returnsCandidate.condition ~ ") && (" ~ combination.condition ~ ") && " ~ layout(node,
                                name) ~ " && " ~ linkage, variants);
                }
            }
        }

        if (result.values.length == 0)
        {
            result.reason = "no supported C representation candidates for " ~ node["name"].str;
        }

        return result;
    }
}

private string compatibilityExpression(string cAddress, Candidate[] candidates,
        bool functionDeclaration, ref CheckMetadata check)
{
    string[] expressions;
    string[] incompletePrototypes;

    foreach (candidate; candidates)
    {
        auto suffix = functionDeclaration ? "" : " *";
        auto compatible = "(_Generic((" ~ cAddress ~ "), " ~ candidate.type
            ~ suffix ~ ": 1, default: 0) && (" ~ candidate.condition ~ "))";

        expressions ~= compatible;

        foreach (variantType; candidate.arityVariants)
        {
            incompletePrototypes ~= "(" ~ compatible ~ " && _Generic(("
                ~ cAddress ~ "), " ~ variantType ~ suffix ~ ": 1, default: 0))";
        }
    }

    auto expression = expressions.join(" || ");

    if (incompletePrototypes.length)
    {
        check.unsupportedValue = "2";
        check.unsupportedReason = "C callable type accepts incompatible parameter counts; "
            ~ "a complete prototype is required, including nested callbacks";
        expression = "(" ~ incompletePrototypes.join(" || ") ~ ") ? 2 : (" ~ expression ~ ")";
    }

    return expression;
}

private void representation(ref Probe probe, ref RepresentationMatcher matcher,
        string label, string cAddress, JSONValue node, bool functionDeclaration = false)
{
    auto check = CheckMetadata(label, functionDeclaration ? "declaration" : "representation",
            functionDeclaration ? "declaration" : "representation",
            "C11 compatible types; D-target integer alternatives guarded by C layout; "
            ~ "named aggregates use selected mappings; const/immutable map to C const; "
            ~ "D char maps to C char, not encoding, signedness or ownership guarantees");

    check.cExpression = cAddress;
    check.dType = node.type == JSONType.object ? node["name"].str : "";

    auto choices = matcher.candidates(node);

    if (choices.reason.length)
    {
        matcher.declarations = "";
        probe.pendingChecks ~= PendingCheck(check, "unsupported", choices.reason);
        return;
    }

    probe.cSource ~= matcher.declarations;
    matcher.declarations = "";

    auto expression = compatibilityExpression(cAddress, choices.values,
            functionDeclaration, check);

    measurement(probe, label ~ " " ~ check.property, expression, "1", "1", check);
}

private void typeMeasurements(ref Probe probe, ref RepresentationMatcher matcher, string label, string cType,
        string dType, JSONValue descriptor = JSONValue.init, bool selectedAggregate = false)
{
    if (descriptor.type == JSONType.object && descriptor["kind"].str == "aggregate")
    {
        if (descriptor["complete"].type != JSONType.true_ || matcher.isOpaque(descriptor))
        {
            representation(probe, matcher, label, "&((" ~ cType ~ "){0})", descriptor);
            return;
        }
    }

    measurement(probe, label ~ " sizeof", "sizeof(" ~ cType ~ ")", "(" ~ dType ~ ").sizeof",
            "", CheckMetadata(label, "sizeof", "layout", "compiler layout"));
    measurement(probe, label ~ " alignof", "_Alignof(" ~ cType ~ ")", "(" ~ dType ~ ").alignof",
            "", CheckMetadata(label, "alignof", "layout", "compiler layout"));

    if (selectedAggregate && descriptor.type == JSONType.object
            && descriptor["kind"].str == "aggregate")
    {
        return;
    }

    representation(probe, matcher, label, "&((" ~ cType ~ "){0})", descriptor);
}

Probe generate(JSONValue manifest, JSONValue reflection = JSONValue.init)
{
    /*
     * Validate the manifest's shape, not a home-grown subset of C or D syntax.
     * Expressions and source fragments remain trusted compiler input; unknown
     * keys are errors so a misspelled check cannot disappear silently.
     */
    validateManifest(manifest);

    auto headers = strings(manifest, "headers", true);
    auto imports = strings(manifest, "imports", true);
    auto types = arrayValue(manifest, "types");
    auto constants = arrayValue(manifest, "constants");
    auto functions = arrayValue(manifest, "functions");
    auto calls = arrayValue(manifest, "calls");

    enforce(types.length + constants.length + functions.length + calls.length != 0,
            "manifest must select at least one type, constant, function or call");

    Probe probe;
    auto matcher = RepresentationMatcher(reflection, types);
    bool reflected = reflection.type == JSONType.object;

    probe.cSource = "#include <stdio.h>\n" ~ "#include <stddef.h>\n" ~ "#include <stdint.h>\n"
        ~ "#include <inttypes.h>\n" ~ "#include <limits.h>\n" ~ "#include <float.h>\n";

    probe.dSource = q{
        import std.stdio : writeln;
        import std.traits : isIntegral, isSomeChar,
            OriginalType, Unqual, isStaticArray;
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

    measurement(probe, "baseline pointer.sizeof", "sizeof(void*)", "(void*).sizeof",
            "", CheckMetadata("target", "pointer.sizeof", "target", "compiler target"));

    auto endianPrefix = rowPrefix(probe.labels.length);

    probe.labels ~= "baseline endianness";
    probe.expectedValues ~= "";
    probe.checks ~= CheckMetadata("target", "endianness", "target", "compiler target");

    probe.cSource ~= "    uint16_t dabiprobe_endian = 1;\n";
    probe.cSource ~= "    printf(\"" ~ endianPrefix
        ~ "%s\\n\", *(unsigned char*)&dabiprobe_endian ? \"little\" : \"big\");\n";
    probe.dSource ~= "    version (LittleEndian) writeln(\"" ~ endianPrefix
        ~ "little\");\n" ~ "    else writeln(\"" ~ endianPrefix ~ "big\");\n";

    foreach (typeIndex, type; types)
    {
        objectKeys(type, ["c", "d", "fields", "opaque"], "type");

        auto cType = requiredText(type, "c", "type");
        auto dType = requiredText(type, "d", "type");
        auto label = cType ~ " <-> " ~ dType;

        auto descriptor = reflected ? reflection["types"][typeIndex]["type"] : JSONValue.init;
        auto allFields = reflected ? reflection["types"][typeIndex]["fields"].array : null;
        auto opaque = "opaque" in type.object;

        if (opaque !is null && opaque.type == JSONType.true_)
        {
            auto check = CheckMetadata(label, "object layout", "layout",
                    "explicit opaque handle mapping");

            if (!reflected || descriptor["kind"].str != "aggregate")
            {
                probe.pendingChecks ~= PendingCheck(check, "unsupported",
                        "opaque mapping requires a compiler-reflected D aggregate type");
            }
            else
            {
                probe.pendingChecks ~= PendingCheck(check, "unchecked", "opaque mapping does not inspect object size, alignment or members; pointer contracts are checked separately");
            }

            continue;
        }

        if (reflected && descriptor["kind"].str == "aggregate"
                && descriptor["complete"].type != JSONType.true_)
        {
            probe.pendingChecks ~= PendingCheck(CheckMetadata(label,
                    "object layout", "layout", "complete aggregate required"),
                    "unsupported",
                    "incomplete aggregate requires an explicit opaque:true type mapping");
            continue;
        }

        typeMeasurements(probe, matcher, label, cType, dType, descriptor, true);

        JSONValue[] selectedFields;

        if (auto fields = "fields" in type.object)
        {
            if (fields.type == JSONType.array)
            {
                selectedFields = fields.array;
            }
            else if (reflected)
            {
                foreach (field; allFields)
                {
                    selectedFields ~= field["name"];
                }

                if (descriptor["kind"].str != "aggregate")
                {
                    probe.pendingChecks ~= PendingCheck(CheckMetadata(label,
                            "fields", "layout", "reflected instance fields"),
                            "unsupported", "fields:'*' requires a D struct or union");
                }
            }
            else
            {
                probe.pendingChecks ~= PendingCheck(CheckMetadata(label,
                        "fields", "layout", "reflected instance fields"),
                        "unsupported", "compiler reflection is required for fields:'*'");
            }
        }

        string[] selectedNames;

        foreach (field; selectedFields)
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

            selectedNames ~= dField;

            measurement(probe, fieldLabel ~ " offsetof",
                    "offsetof(" ~ cType ~ ", " ~ cField ~ ")", dExpression ~ ".offsetof",
                    "", CheckMetadata(fieldLabel, "offsetof", "layout", "compiler layout"));
            measurement(probe, fieldLabel ~ " sizeof", "sizeof(" ~ cExpression ~ ")", dExpression ~ ".sizeof", "",
                    CheckMetadata(fieldLabel, "sizeof", "layout", "compiler layout"));

            JSONValue fieldType;

            foreach (candidate; allFields)
            {
                if (candidate["name"].str == dField)
                {
                    fieldType = candidate["type"];
                    break;
                }
            }

            representation(probe, matcher, fieldLabel, "&(" ~ cExpression ~ ")", fieldType);
        }

        if (reflected && descriptor["kind"].str == "aggregate")
        {
            foreach (field; allFields)
            {
                if (!selectedNames.canFind(field["name"].str))
                {
                    probe.pendingChecks ~= PendingCheck(CheckMetadata(label ~ " field " ~ field["name"].str,
                            "coverage", "representation",
                            "selected fields only"), "unchecked",
                            "D instance field was not selected");
                }
            }

            probe.pendingChecks ~= PendingCheck(CheckMetadata(label,
                    "C member completeness", "representation", "D-reflected member selection"),
                    "unchecked", "C-only members and padding contents are not enumerated");
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
        probe.checks ~= CheckMetadata("constant " ~ cExpression ~ " <-> " ~ dExpression,
                "value", "value", "integral value through 64 bits");

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

        if (returnValue is null)
        {
            auto descriptor = reflected ? reflection["functions"][index]["type"] : JSONValue.init;
            auto label = "function " ~ cFunction ~ " <-> " ~ dFunction;

            representation(probe, matcher, label, "&" ~ cFunction, descriptor, true);

            probe.pendingChecks ~= PendingCheck(CheckMetadata(label, "behavior",
                    "call", "declarations are not executed"),
                    "unchecked",
                    "declaration compatibility does not establish behavior, ownership or lifetime");
            continue;
        }

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

            auto descriptor = reflected ? reflection["functions"][index]["parameters"][parameterIndex]
                : JSONValue.init;

            typeMeasurements(probe, matcher,
                    label ~ " parameter " ~ to!string(parameterIndex), name, name, descriptor);
        }

        /* Literal void needs no layout probe and cannot be used with sizeof. */
        bool cVoid = cReturn.strip == "void";
        bool dVoid = dReturn.strip == "void";

        if (cVoid != dVoid)
        {
            measurement(probe, label ~ " return void", cVoid ? "1" : "0", dVoid ? "1" : "0", "",
                    CheckMetadata(label, "return void", "declaration", "explicit signature"));
        }
        else if (!cVoid)
        {
            auto descriptor = reflected ? reflection["functions"][index]["returns"] : JSONValue
                .init;

            typeMeasurements(probe, matcher, label ~ " return",
                    typeName ~ "_return", typeName ~ "_return", descriptor);
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
        auto check = CheckMetadata(label, "declaration", "declaration",
                "explicit C and D signatures must both match; native C prototype completeness is required");
        auto contract = reflected ? reflection["functions"][index] : JSONValue.init;
        auto choices = matcher.explicitCandidates(typeName ~ "_return",
                parameterNames, variadic, contract);

        check.cExpression = "&" ~ cFunction;
        check.dType = reflected ? contract["type"]["name"].str : "";

        if (choices.reason.length)
        {
            matcher.declarations = "";
            probe.pendingChecks ~= PendingCheck(check, "unsupported", choices.reason);
        }
        else
        {
            probe.cSource ~= matcher.declarations;
            matcher.declarations = "";

            auto complete = compatibilityExpression(check.cExpression, choices.values, true, check);
            auto compatible = "_Generic((&" ~ cFunction ~ "), " ~ typeName ~ ": 1, default: 0)";

            measurement(probe, label ~ " declaration", "(" ~ complete ~ ") == 2 ? 2 : (" ~ compatible ~ ")",
                    "(is(" ~ typeName ~ "_actual : " ~ typeName ~ ") ? 1 : 0)", "1", check);
        }

        probe.pendingChecks ~= PendingCheck(CheckMetadata(label, "behavior",
                "call", "declarations are not executed"), "unchecked",
                "declaration compatibility does not establish behavior, ownership or lifetime");
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
        probe.callChecks ~= CheckMetadata(name, "call assertion", "call",
                "explicit bool expression must be true");
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
