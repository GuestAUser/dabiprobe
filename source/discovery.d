/*
 * Compile-only D reflection for selected binding declarations.
 *
 * The selected compiler evaluates the reflection helpers and emits JSON through
 * pragma(msg). No discovery executable is linked or run.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module discovery;

import probes : arrayValue, requiredText, strings, text, validateManifest;
import std.array : join, split;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : startsWith, strip;

string discoverySource(JSONValue manifest)
{
    validateManifest(manifest);

    string source = "module dabiprobe_discovery;\n";

    foreach (moduleName; strings(manifest, "imports", true))
    {
        source ~= "import " ~ moduleName ~ ";\n";
    }

    if (auto extra = "dSource" in manifest.object)
    {
        source ~= text(*extra, "dSource", false) ~ "\n";
    }

    string[] selected;

    foreach (entry; arrayValue(manifest, "types"))
    {
        selected ~= requiredText(entry, "d", "type");
    }

    source ~= "import std.meta : AliasSeq;\n";
    source ~= "alias DabiprobeSelected = AliasSeq!(" ~ selected.join(", ") ~ ");\n";
    source ~= q"HELPERS
        import core.stdc.config : c_long;
        import std.json : JSONValue;
        import std.traits : FieldNameTuple, FunctionAttribute, OriginalType,
            Parameters, ParameterStorageClass, ParameterStorageClassTuple,
            ReturnType, Unqual, Variadic, functionAttributes, functionLinkage,
            isFloatingPoint, isFunctionPointer, isIntegral, isSomeChar,
            isStaticArray, isUnsigned, variadicFunctionStyle;

        JSONValue dabiprobeType(T, size_t depth = 0)()
        {
            alias Base = Unqual!(OriginalType!T);

            auto result = JSONValue([
                "name": JSONValue(T.stringof),
                "kind": JSONValue("unsupported"),
                "qualifier": JSONValue(is(T == const) || is(T == immutable) ? "const" : "")
            ]);

            static if (depth >= 12)
            {
                result["reason"] = "type nesting exceeds the reflection depth limit of 12";
            }
            else static if (is(T == shared) || is(T == inout))
            {
                result["reason"] = "shared and inout qualifiers have no inferred C contract";
            }
            else static if (is(Base == void))
            {
                result["kind"] = "void";
            }
            else
            {
                enum complete = __traits(compiles, Base.sizeof, Base.alignof);
                result["complete"] = complete;

                static if (complete)
                {
                    result["size"] = Base.sizeof;
                    result["align"] = Base.alignof;
                }

                static if (isFunctionPointer!Base)
                {
                    result["kind"] = "function";
                    result["linkage"] = functionLinkage!Base;
                    result["returns"] = dabiprobeType!(ReturnType!Base, depth + 1)();

                    JSONValue[] parameters;

                    static foreach (index, Parameter; Parameters!Base)
                    {
                        parameters ~= dabiprobeType!(Parameter, depth + 1)();

                        static if ((ParameterStorageClassTuple!Base[index]
                                & (ParameterStorageClass.ref_ | ParameterStorageClass.out_
                                    | ParameterStorageClass.lazy_ | ParameterStorageClass.in_)) != 0)
                        {
                            result["reason"] = "ref, out, lazy and in parameters require an explicit contract";
                        }

                        static if (isStaticArray!Parameter)
                        {
                            result["reason"] = "D static array parameters do not use C array-to-pointer decay";
                        }
                    }

                    result["parameters"] = JSONValue(parameters);

                    static if (variadicFunctionStyle!Base != Variadic.no)
                    {
                        result["reason"] = "variadic signatures require an explicit contract";
                    }

                    static if ((functionAttributes!Base & FunctionAttribute.ref_) != 0)
                    {
                        result["reason"] = "ref returns require an explicit contract";
                    }

                    static if (isStaticArray!(ReturnType!Base))
                    {
                        result["reason"] = "D static array returns have no C function return representation";
                    }
                }
                else static if (is(Base == Element*, Element))
                {
                    result["kind"] = "pointer";
                    result["element"] = dabiprobeType!(Element, depth + 1)();
                }
                else static if (isStaticArray!Base)
                {
                    result["kind"] = "array";
                    result["length"] = Base.length;
                    result["element"] = dabiprobeType!(typeof(Base.init[0]), depth + 1)();
                }
                else static if (is(Base == bool))
                {
                    result["kind"] = "bool";
                }
                else static if (is(Base == char))
                {
                    result["kind"] = "char";
                }
                else static if (isIntegral!Base || isSomeChar!Base)
                {
                    result["kind"] = isUnsigned!Base || isSomeChar!Base ? "unsigned" : "signed";
                }
                else static if (isFloatingPoint!Base)
                {
                    result["kind"] = "float";
                    result["format"] = is(Base == float) ? "float" : is(Base == double) ? "double" : "long double";
                    result["digits"] = Base.mant_dig;
                    result["maxExponent"] = Base.max_exp;
                }
                else static if (is(Base == struct) || is(Base == union))
                {
                    result["kind"] = "aggregate";
                    result["mapping"] = -1;

                    static foreach (index, Selected; DabiprobeSelected)
                    {
                        static if (is(Base == Unqual!Selected))
                        {
                            if (result["mapping"].integer >= 0)
                            {
                                result["reason"] = "multiple selected mappings name the same D aggregate";
                            }

                            result["mapping"] = cast(long) index;
                        }
                    }
                }
                else
                {
                    result["reason"] = "D type has no supported C representation";
                }
            }

            return result;
        }

        JSONValue dabiprobeFields(T, bool inspect = true)()
        {
            JSONValue[] fields;

            static if (inspect && __traits(compiles, T.sizeof, T.alignof)
                    && (is(T == struct) || is(T == union)))
            {
                static foreach (name; FieldNameTuple!T)
                {
                    fields ~= JSONValue([
                        "name": JSONValue(name),
                        "type": dabiprobeType!(typeof(__traits(getMember, T, name)))()
                    ]);
                }
            }

            return JSONValue(fields);
        }

        JSONValue dabiprobeDiscover()
        {
            JSONValue[] types;
            JSONValue[] functions;
HELPERS";

    foreach (entry; arrayValue(manifest, "types"))
    {
        auto dType = requiredText(entry, "d", "type");
        auto opaque = "opaque" in entry.object;
        auto inspect = opaque is null || opaque.type != JSONType.true_;

        source ~= "types ~= JSONValue([\"type\": dabiprobeType!(" ~ dType
            ~ ")(), \"fields\": dabiprobeFields!(" ~ dType ~ ", " ~ (inspect
                    ? "true" : "false") ~ ")()]);\n";
    }

    foreach (entry; arrayValue(manifest, "functions"))
    {
        auto dFunction = requiredText(entry, "d", "function");

        source ~= "{ auto entry = JSONValue([\"type\": dabiprobeType!(typeof(&"
            ~ dFunction ~ "))()]);\n";

        if (auto returns = "returns" in entry.object)
        {
            source ~= "entry[\"returns\"] = dabiprobeType!(" ~ requiredText(*returns,
                    "d", "function.returns") ~ ")();\n";
            source ~= "JSONValue[] parameters;\n";

            foreach (parameter; arrayValue(entry, "parameters", true))
            {
                source ~= "parameters ~= dabiprobeType!(" ~ requiredText(parameter,
                        "d", "function parameter") ~ ")();\n";
            }

            source ~= "entry[\"parameters\"] = JSONValue(parameters);\n";
        }

        source ~= "functions ~= entry; }\n";
    }

    source ~= q"FINISH
            return JSONValue([
                "types": JSONValue(types),
                "functions": JSONValue(functions),
                "integers": JSONValue([
                    JSONValue(["c": JSONValue("signed char"), "size": JSONValue(byte.sizeof), "align": JSONValue(byte.alignof)]),
                    JSONValue(["c": JSONValue("short"), "size": JSONValue(short.sizeof), "align": JSONValue(short.alignof)]),
                    JSONValue(["c": JSONValue("int"), "size": JSONValue(int.sizeof), "align": JSONValue(int.alignof)]),
                    JSONValue(["c": JSONValue("long"), "size": JSONValue(c_long.sizeof), "align": JSONValue(c_long.alignof)]),
                    JSONValue(["c": JSONValue("long long"), "size": JSONValue(long.sizeof), "align": JSONValue(long.alignof)])
                ])
            ]);
        }

        enum dabiprobeDiscovered = dabiprobeDiscover();
        pragma(msg, "DABIPROBE_DISCOVERY\t" ~ dabiprobeDiscovered.toString());
FINISH";

    return source;
}

JSONValue parseDiscovery(string compilerOutput)
{
    enum prefix = "DABIPROBE_DISCOVERY\t";

    JSONValue result;
    bool found;

    foreach (line; compilerOutput.split("\n"))
    {
        if (!line.startsWith(prefix))
        {
            continue;
        }

        enforce(!found, "D discovery emitted duplicate reflection records");

        result = parseJSON(line[prefix.length .. $].strip);
        found = true;
    }

    enforce(found && result.type == JSONType.object, "D discovery did not emit a reflection record");

    return result;
}
