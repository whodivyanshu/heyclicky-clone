# Loads the built bridge from .NET and calls it through P/Invoke, which is how the Windows app uses it.
# Exits with an error if the DLL won't load, a function isn't exported, or a safety rule gives the wrong answer.
param([Parameter(Mandatory)][string]$Dll)

$ErrorActionPreference = 'Stop'
$path = (Resolve-Path $Dll).Path
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class JarvisSmoke {
    [DllImport(@"$path", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr jarvis_call(byte[] method, byte[] parameters);
    [DllImport(@"$path", CallingConvention = CallingConvention.Cdecl)]
    static extern void jarvis_free(IntPtr text);

    static byte[] Utf8(string text) {
        return System.Text.Encoding.UTF8.GetBytes(text + "\0");
    }

    public static string Call(string method, string json) {
        IntPtr result = jarvis_call(Utf8(method), Utf8(json));
        try { return Marshal.PtrToStringUTF8(result); }
        finally { jarvis_free(result); }
    }
}
"@

function Expect($method, $json, $expected) {
    $actual = [JarvisSmoke]::Call($method, $json)
    if ($actual -ne $expected) {
        throw "$method $json returned $actual, expected $expected"
    }
    Write-Host "ok  $method $json -> $actual"
}

# Parses compactly enough to compare exactly, and covers non-English text crossing the boundary.
Expect 'key.parse' '{"text":"alt+f4"}' '{"ok":null}'
Expect 'key.parse' '{"text":"win+r"}' '{"ok":null}'
Expect 'risk.key' '{"text":"return","context":{"appName":"WhatsApp"}}' '{"ok":true}'
Expect 'windows.refusesKeyboard' '{"process":"cmd.exe","title":""}' '{"ok":true}'
Expect 'confirm.decision' '{"transcript":"हाँ"}' '{"ok":true}'
Expect 'no.such.method' '{}' '{"error":"Unknown method: no.such.method"}'
Write-Host 'The bridge works from .NET.'
