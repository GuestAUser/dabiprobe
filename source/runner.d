/*
 * Portable compiler and probe execution.
 *
 * Handles literal process arguments, host-specific output paths, and private
 * temporary workspaces on Windows and POSIX hosts.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module runner;

import std.algorithm : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file : rmdirRecurse, tempDir;
import std.path : absolutePath, buildPath;
import std.process : Config, execute;
import std.stdio : stderr;

version (Windows)
{
    import core.sys.windows.accctrl : SE_OBJECT_TYPE;
    import core.sys.windows.aclapi : GetNamedSecurityInfoW;
    import core.sys.windows.windows;
    import std.utf : toUTF16z;
    import std.uuid : randomUUID;

    pragma(lib, "advapi32");

    /*
     * Some filesystems accept a security descriptor without enforcing it.
     * Read the DACL back before writing probe source or executables; otherwise
     * a supposedly private directory on a shared filesystem could be public.
     */
    private void verifyWorkspacePermissions(string workspace, PSID userSid)
    {
        PACL acl;
        PSECURITY_DESCRIPTOR descriptor;

        auto status = GetNamedSecurityInfoW(cast(wchar*) workspace.toUTF16z,
                SE_OBJECT_TYPE.SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, null,
                null, &acl, null, &descriptor);

        enforce(status == 0, "could not verify private temporary directory permissions" ~ " (Windows error " ~ to!string(
                status) ~ ")" ~ "; use an ACL-capable temporary filesystem");

        scope (exit)
        {
            LocalFree(descriptor);
        }

        SECURITY_DESCRIPTOR_CONTROL control;
        DWORD revision;

        enforce(GetSecurityDescriptorControl(descriptor, &control, &revision) != 0
                && (control & SE_DACL_PROTECTED) != 0 && acl !is null && acl.AceCount == 1,
                "temporary filesystem did not preserve private directory permissions");

        void* entry;

        enforce(GetAce(acl, 0, &entry) != 0, "could not read temporary directory permissions");

        auto access = cast(ACCESS_ALLOWED_ACE*) entry;
        enum inheritance = OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;

        enforce(access.Header.AceType == ACCESS_ALLOWED_ACE_TYPE && access.Mask == FILE_ALL_ACCESS
                && (access.Header.AceFlags & inheritance) == inheritance
                && EqualSid(cast(PSID)&access.SidStart, userSid) != 0,
                "temporary filesystem did not preserve current-user-only access");
    }
}
else version (Posix)
{
    import core.sys.posix.stdlib : mkdtemp;
    import std.string : fromStringz;
}
else
{
    static assert(false, "dabiprobe requires a Windows or POSIX host");
}

/*
 * Pass literal argv elements: flags and paths are never joined into a shell
 * command. execute merges stdout/stderr; compiler diagnostics are forwarded,
 * while unsolicited probe diagnostics fail the caller's strict row parser.
 */
string run(string[] arguments, string directory, string stage, bool diagnostics = false)
{
    auto result = execute(arguments, null, Config.none, size_t.max, directory);

    if (diagnostics && result.output.length)
    {
        stderr.write(result.output);
    }

    enforce(result.status == 0, stage ~ " failed (exit " ~ to!string(
            result.status) ~ ")" ~ (diagnostics ? "" : ":\n" ~ result.output));

    return result.output;
}

string compilerPath(string compiler)
{
    enforce(compiler.length != 0 && !compiler.canFind('\0'),
            "compiler path must not be empty or contain NUL");

    version (Windows)
    {
        bool hasPath = compiler.canFind('/') || compiler.canFind('\\') || compiler.canFind(':');
    }
    else
    {
        bool hasPath = compiler.canFind('/');
    }

    /* Preserve PATH lookup for bare names; anchor explicit paths before chdir. */
    return hasPath ? absolutePath(compiler) : compiler;
}

void identifyDCompiler(string compiler, string directory)
{
    auto output = run([compiler, "--version"], directory, "D compiler identification");

    enforce(output.canFind("LDC") || output.canFind("DMD") || output.canFind("Digital Mars D Compiler"),
            "unsupported D compiler: expected native LDC or DMD using -of= output syntax");
}

string createWorkspace(string parent = tempDir())
{
    version (Windows)
    {
        /*
         * Build a protected, inheritable DACL for the current token's user.
         * Supplying it during creation avoids a window of broader inherited
         * access. Keep the SID and ACL buffers alive until creation completes.
         */
        HANDLE token;

        enforce(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY,
                &token) != 0, "could not read current user token");

        scope (exit)
        {
            CloseHandle(token);
        }

        DWORD tokenSize;

        GetTokenInformation(token, TOKEN_INFORMATION_CLASS.TokenUser, null, 0, &tokenSize);
        enforce(tokenSize != 0, "could not determine current user token size");

        auto tokenData = new ubyte[tokenSize];

        enforce(GetTokenInformation(token, TOKEN_INFORMATION_CLASS.TokenUser, tokenData.ptr,
                tokenSize, &tokenSize) != 0, "could not read current user identity");

        auto userSid = (cast(TOKEN_USER*) tokenData.ptr).User.Sid;

        /* SidStart is a placeholder; reserve the actual variable-length SID. */
        auto aclSize = cast(DWORD)(
                ACL.sizeof + ACCESS_ALLOWED_ACE.sizeof - DWORD.sizeof + GetLengthSid(userSid));
        auto aclData = new ubyte[aclSize];
        auto acl = cast(ACL*) aclData.ptr;

        enforce(InitializeAcl(acl, aclSize, ACL_REVISION) != 0 && AddAccessAllowedAceEx(acl,
                ACL_REVISION, OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE,
                FILE_ALL_ACCESS, userSid) != 0, "could not create private directory permissions");

        SECURITY_DESCRIPTOR descriptor;

        enforce(InitializeSecurityDescriptor(&descriptor,
                SECURITY_DESCRIPTOR_REVISION) != 0 && SetSecurityDescriptorDacl(&descriptor,
                true, acl, false) != 0 && SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED,
                SE_DACL_PROTECTED) != 0, "could not protect temporary directory permissions");

        SECURITY_ATTRIBUTES attributes;

        attributes.nLength = SECURITY_ATTRIBUTES.sizeof;
        attributes.lpSecurityDescriptor = &descriptor;

        foreach (attempt; 0 .. 16)
        {
            auto workspace = absolutePath(buildPath(parent, "dabiprobe-" ~ randomUUID().toString()));

            if (CreateDirectoryW(workspace.toUTF16z, &attributes))
            {
                scope (failure)
                {
                    RemoveDirectoryW(workspace.toUTF16z);
                }

                verifyWorkspacePermissions(workspace, userSid);

                return workspace;
            }

            auto error = GetLastError();

            enforce(error == ERROR_ALREADY_EXISTS,
                    "could not create private temporary directory (Windows error " ~ to!string(
                        error) ~ ")");
        }

        throw new Exception("could not create a unique private temporary directory");
    }
    else version (Posix)
    {
        /* mkdtemp atomically chooses an unused name and creates mode 0700. */
        auto templatePath = (buildPath(parent, "dabiprobe-XXXXXX") ~ "\0").dup;

        enforce(mkdtemp(templatePath.ptr) !is null, "could not create private temporary directory");

        return absolutePath(fromStringz(templatePath.ptr).idup);
    }
}

void removeWorkspace(string workspace)
{
    rmdirRecurse(workspace);
}

string executablePath(string workspace, string name)
{
    version (Windows)
    {
        return buildPath(workspace, name ~ ".exe");
    }
    else
    {
        return buildPath(workspace, name);
    }
}

string objectPath(string workspace, string name)
{
    version (Windows)
    {
        return buildPath(workspace, name ~ ".obj");
    }
    else
    {
        return buildPath(workspace, name ~ ".o");
    }
}

void compileC(string compiler, string source, string output, string directory,
        string[] flags = null, bool objectOnly = false)
{
    auto arguments = [compiler, "-std=c11", "-I", directory] ~ flags;

    if (objectOnly)
    {
        arguments ~= "-c";
    }

    run(arguments ~ [source, "-o", output], directory, "C compilation", true);
}

void compileD(string compiler, string source, string output, string directory,
        string workspace, string[] flags = null, string[] objects = null)
{
    /* Both executables and intermediate objects must stay inside the workspace. */
    run([compiler, "-I" ~ directory] ~ flags ~ [source] ~ objects ~ [
        "-of=" ~ output, "-od=" ~ workspace
    ], directory, "D compilation", true);
}
