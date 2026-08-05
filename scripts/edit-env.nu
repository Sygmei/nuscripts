#!/usr/bin/env nu
# Edit .env.age without leaving plaintext on disk.
# Decrypts to a temp file in RAM, opens editor, re-encrypts, then securely wipes.

let repo_root = ($env.CURRENT_FILE | path dirname | path dirname)
let key = ($repo_root | path join "AGE-KEY.txt")
let enc = ($repo_root | path join ".env.age")
let pubkey = (^age-keygen -y $key | str trim)

if not ($key | path exists) {
    error make {
        msg: $"AGE-KEY.txt not found. Run: age-keygen -o ($key)"
    }
}

let tmp_dir = ($env.USERPROFILE | path join ".cache")
if not ($tmp_dir | path exists) {
    mkdir $tmp_dir
}
let tmp = ($tmp_dir | path join "eggplant-edit-env.tmp")

try {
    # Decrypt to temp
    ^age -d -i $key $enc | save --force $tmp

    # Open editor
    let editor = ($env.EDITOR? | default $env.EDITOR? | default "vim")
    do { ^$editor $tmp } | complete | ignore

    # Re-encrypt only if changed
    let original = (^age -d -i $key $enc | str trim)
    let modified = (open --raw $tmp | str trim)

    if $original != $modified {
        ^age -r $pubkey -o $enc $tmp
        print "✅ .env.age updated and re-encrypted."
    } else {
        print "No changes detected."
    }
} finally {
    # Always delete temp file
    if ($tmp | path exists) {
        rm -f $tmp
    }
}
