const ssh_sync_tag = "ssh-sync"
const ssh_sync_begin = "# ssh-sync begin"
const ssh_sync_end = "# ssh-sync end"
const ssh_sync_legacy_begin = "# ssh-bw-sync begin"
const ssh_sync_legacy_end = "# ssh-bw-sync end"

source ssh-sync.config.nu

def ssh-sync-error [message: string] {
    error make { msg: $message }
}

def ssh-sync-require-command [name: string] {
    if ((which $name | length) == 0) {
        ssh-sync-error $"Required command not found: ($name)"
    }
}

def ssh-sync-config-path [] {
    $nu.home-path | path join ".config" "nushell" "ssh-sync.config.nu"
}

def ssh-sync-templates-dir [] {
    $nu.home-path | path join ".config" "nushell" "ssh-sync-templates"
}

def ssh-sync-template-path [template: string] {
    ssh-sync-templates-dir | path join $"ssh-sync.config.($template).nu"
}

def ssh-sync-require-value [label: string, value: any, entry_name: string] {
    let text = ($value | default "" | into string)

    if ($text | str trim | is-empty) {
        ssh-sync-error $"SSH entry '($entry_name)' is missing required ($label)"
    }

    $text
}

def ssh-sync-require-ssh-config-value [label: string, value: any, entry_name: string] {
    let text = (ssh-sync-require-value $label $value $entry_name | str trim)

    if ($text | str contains "\n") {
        ssh-sync-error $"SSH entry '($entry_name)' has a newline in ($label), which cannot be written safely to ssh config"
    }

    $text
}

def ssh-sync-require-record [entry: any] {
    if not (($entry | describe) | str starts-with "record") {
        ssh-sync-error "ssh-sync-list must return SSH entry records"
    }
}

def ssh-sync-safe-file-name [name: any] {
    let clean = ($name | default "" | into string | str trim)

    if ($clean | is-empty) {
        ssh-sync-error "SSH entry has an empty name"
    }

    if (($clean | str contains "/") or ($clean | str contains "\\")) {
        ssh-sync-error $"SSH entry name '($clean)' cannot be used as a key filename because it contains a path separator"
    }

    if ($clean | str contains "\n") {
        ssh-sync-error $"SSH entry name '($clean)' cannot be used as a key filename because it contains a newline"
    }

    $clean
}

def ssh-sync-quote-ssh-value [value: string] {
    $'"($value | str replace --all "\\" "\\\\" | str replace --all "\"" "\\\"")"'
}

def ssh-sync-public-key-core [key: string] {
    let parts = ($key | str trim | split row --regex '\s+')

    if (($parts | length) < 2) {
        ssh-sync-error "Invalid SSH public key"
    }

    $parts.1
}

def ssh-sync-strip-generated-blocks [config: string] {
    mut keep = []
    mut in_generated_block = false

    for line in ($config | lines) {
        if (($line | str starts-with $ssh_sync_begin) or ($line | str starts-with $ssh_sync_legacy_begin)) {
            $in_generated_block = true
            continue
        }

        if $in_generated_block {
            if (($line | str starts-with $ssh_sync_end) or ($line | str starts-with $ssh_sync_legacy_end)) {
                $in_generated_block = false
            }

            continue
        }

        $keep = ($keep | append $line)
    }

    if $in_generated_block {
        ssh-sync-error $"Existing ssh config contains an unterminated ($ssh_sync_tag) block"
    }

    $keep | str join "\n"
}

def "ssh-sync init" [
    --template: string = "default"
    --force
] {
    let templates_dir = (ssh-sync-templates-dir)
    let template_path = (ssh-sync-template-path $template)
    let config_path = (ssh-sync-config-path)

    mkdir $templates_dir

    if not ($template_path | path exists) {
        ssh-sync-error $"Unknown ssh-sync config template: ($template)"
    }

    if (($config_path | path exists) and (not $force)) {
        ssh-sync-error $"Config already exists: ($config_path). Pass --force to overwrite it."
    }

    open --raw $template_path | save --force $config_path

    {
        template: $template
        config: $config_path
    }
}

def "ssh-sync store-secret" [] {
    if (ssh-sync-secret-store-interactive) == true {
        print "Stored ssh-sync secret."
        return
    }

    let secret = (input --suppress-output "ssh-sync secret to store: ")

    if (ssh-sync-secret-store $secret) != true {
        ssh-sync-error "No secret store accessor is configured. Edit ssh-sync.config.nu."
    }

    print "Stored ssh-sync secret."
}

def "ssh-sync delete-secret" [] {
    if (ssh-sync-secret-delete) != true {
        ssh-sync-error "No secret delete accessor is configured. Edit ssh-sync.config.nu."
    }

    print "Deleted ssh-sync secret."
}

def --env ssh-sync [] {
    ssh-sync-require-command ssh-keygen

    let entries = (ssh-sync-list)

    let ssh_dir = ($nu.home-path | path join ".ssh")
    let config_path = ($ssh_dir | path join "config")
    let tmp_dir = ($ssh_dir | path join $".ssh-sync.tmp.(random uuid)")

    mkdir $ssh_dir
    ^chmod 700 $ssh_dir
    mkdir $tmp_dir

    mut config_blocks = []
    mut staged_keys = []

    try {
        for entry in $entries {
            ssh-sync-require-record $entry

            let entry_name = (ssh-sync-safe-file-name ($entry | get -o name))
            let private_key = (ssh-sync-require-value "private_key" ($entry | get -o private_key) $entry_name)
            let public_key = (ssh-sync-require-value "public_key" ($entry | get -o public_key) $entry_name | str trim)
            let hostname = (ssh-sync-require-ssh-config-value "hostname" ($entry | get -o hostname) $entry_name)
            let user = (ssh-sync-require-ssh-config-value "user" ($entry | get -o user) $entry_name)
            let port = ($entry | get -o port | default null)
            let key_path = ($ssh_dir | path join $entry_name)
            let pub_key_path = $"($key_path).pub"
            let staged_key = ($tmp_dir | path join $entry_name)
            let staged_pub_key = $"($staged_key).pub"

            $private_key | save --force $staged_key
            $public_key | save --force $staged_pub_key
            ^chmod 600 $staged_key
            ^chmod 644 $staged_pub_key

            let derived_public_key = (^ssh-keygen -y -f $staged_key | str trim)

            if ((ssh-sync-public-key-core $derived_public_key) != (ssh-sync-public-key-core $public_key)) {
                ssh-sync-error $"Public key mismatch for SSH entry '($entry_name)'"
            }

            $staged_keys = ($staged_keys | append {
                private_from: $staged_key
                public_from: $staged_pub_key
                private_to: $key_path
                public_to: $pub_key_path
            })

            let port_lines = if $port == null {
                []
            } else {
                let port_text = (ssh-sync-require-ssh-config-value "port" $port $entry_name)
                [$"  Port ($port_text)"]
            }
            let block = ([
                $"($ssh_sync_begin) entry: ($entry_name)"
                $"Host ($entry_name)"
                $"  HostName ($hostname)"
                $"  User ($user)"
                ...$port_lines
                $"  IdentityFile (ssh-sync-quote-ssh-value $key_path)"
                "  IdentitiesOnly yes"
                $ssh_sync_end
            ] | str join "\n")

            $config_blocks = ($config_blocks | append $block)
        }

        let current_config = if ($config_path | path exists) { open --raw $config_path } else { "" }
        let preserved_config = (ssh-sync-strip-generated-blocks $current_config | str trim --right)
        let generated_config = ($config_blocks | str join "\n\n")
        let next_config = if ($preserved_config | is-empty) {
            $"($generated_config)\n"
        } else if ($generated_config | is-empty) {
            $"($preserved_config)\n"
        } else {
            $"($preserved_config)\n\n($generated_config)\n"
        }
        let staged_config = ($tmp_dir | path join "config")

        $next_config | save --force $staged_config
        ^chmod 600 $staged_config

        for key in $staged_keys {
            mv --force $key.private_from $key.private_to
            mv --force $key.public_from $key.public_to
        }

        mv --force $staged_config $config_path
        ^chmod 600 $config_path
    } catch {|err|
        rm -rf $tmp_dir
        ssh-sync-error $err.msg
    }

    rm -rf $tmp_dir

    {
        synced_entries: ($entries | length)
        config: $config_path
        key_directory: $ssh_dir
    }
}
