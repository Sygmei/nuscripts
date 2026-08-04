# Bitwarden accessor config for ssh-sync.
#
# This template reads SSH key items from the Bitwarden folder named "SSH".
# Each SSH key item must have custom fields:
# - Host: real remote host
# - User: SSH user
# - Port: optional SSH port
#
# ssh-sync itself only consumes the generic records returned by `ssh-sync-list`.
#
# `ssh-sync-list` returns a table of SSH entry records. Rows may also include
# an optional `port` column when a Bitwarden item defines one.
#
# Example return value:
#
# [
#     {
#         name: "my-server"              # SSH alias and key filename
#         hostname: "example.com"        # Real remote host
#         user: "root"                   # SSH user
#         private_key: $"-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"
#         public_key: "ssh-ed25519 AAAA..."
#         port: 22                        # Optional SSH port
#     }
# ]

def ssh-sync-bitwarden-error [message: string] {
    error make { msg: $message }
}

def ssh-sync-bitwarden-require-command [name: string] {
    if ((which $name | length) == 0) {
        ssh-sync-bitwarden-error $"Required command not found: ($name)"
    }
}

def ssh-sync-bitwarden-secret-helper [] {
    $nu.home-dir | path join ".config" "nushell" "ssh-sync-keychain"
}

def ssh-sync-bitwarden-run-command [command: list<string>] {
    let executable = ($command | first)
    let args = ($command | skip 1)

    run-external $executable ...$args | complete
}

def ssh-sync-bitwarden-run-interactive-command [command: list<string>] {
    let executable = ($command | first)
    let args = ($command | skip 1)

    run-external $executable ...$args
    $env.LAST_EXIT_CODE? | default 0
}

def ssh-sync-bitwarden-secret-get [] {
    let helper = (ssh-sync-bitwarden-secret-helper)

    if not ($helper | path exists) {
        return null
    }

    let result = (ssh-sync-bitwarden-run-command [$helper "get"])

    if $result.exit_code == 2 {
        return null
    }

    if $result.exit_code != 0 {
        ssh-sync-bitwarden-error (
            [
                "Bitwarden secret accessor failed"
                ($result.stderr | str trim)
                ($result.stdout | str trim)
            ]
            | where {|line| not ($line | is-empty) }
            | str join "\n"
        )
    }

    let secret = ($result.stdout | str trim)

    if ($secret | is-empty) {
        ssh-sync-bitwarden-error "Bitwarden secret accessor returned an empty secret"
    }

    $secret
}

# Return type: bool
def ssh-sync-secret-store-interactive []: nothing -> bool {
    let helper = (ssh-sync-bitwarden-secret-helper)

    if not ($helper | path exists) {
        return false
    }

    let exit_code = (ssh-sync-bitwarden-run-interactive-command [$helper "store-interactive"])

    if $exit_code != 0 {
        ssh-sync-bitwarden-error "Could not store Bitwarden secret with the configured accessor"
    }

    true
}

# Return type: bool
def ssh-sync-secret-store [secret: string]: nothing -> bool {
    false
}

# Return type: bool
def ssh-sync-secret-delete []: nothing -> bool {
    let helper = (ssh-sync-bitwarden-secret-helper)

    if not ($helper | path exists) {
        return false
    }

    let result = (ssh-sync-bitwarden-run-command [$helper "delete"])

    if $result.exit_code != 0 {
        ssh-sync-bitwarden-error (
            [
                "Could not delete Bitwarden secret with the configured accessor"
                ($result.stderr | str trim)
                ($result.stdout | str trim)
            ]
            | where {|line| not ($line | is-empty) }
            | str join "\n"
        )
    }

    true
}

def ssh-sync-bitwarden-run-json [args: list<string>] {
    let result = (run-external "bw" ...$args | complete)

    if $result.exit_code != 0 {
        ssh-sync-bitwarden-error (
            [
                $"bw ($args | str join ' ') failed"
                ($result.stderr | str trim)
            ]
            | where {|line| not ($line | is-empty) }
            | str join "\n"
        )
    }

    $result.stdout | from json
}

def ssh-sync-bitwarden-field [item: record, field_name: string] {
    let matches = (
        $item
        | get -o fields
        | default []
        | where name == $field_name
    )

    if (($matches | length) == 0) {
        ""
    } else {
        $matches | first | get -o value | default ""
    }
}

def ssh-sync-bitwarden-port [item: record] {
    let port = (ssh-sync-bitwarden-field $item "Port" | str trim)

    if ($port | is-empty) {
        null
    } else {
        $port | into int
    }
}

def ssh-sync-bitwarden-unlock [secret: string] {
    let unlock_result = (
        with-env { SSH_SYNC_BITWARDEN_SECRET: $secret } {
            ^bw unlock --passwordenv SSH_SYNC_BITWARDEN_SECRET --raw | complete
        }
    )
    let session = ($unlock_result.stdout | str trim)

    if (($unlock_result.exit_code != 0) or ($session | is-empty)) {
        ssh-sync-bitwarden-error (
            [
                "bw unlock --passwordenv SSH_SYNC_BITWARDEN_SECRET --raw did not return a session key"
                ($unlock_result.stderr | str trim)
                ($unlock_result.stdout | str trim)
            ]
            | where {|line| not ($line | is-empty) }
            | str join "\n"
        )
    }

    $session
}

# Return type: table of SSH entry records. Rows may include an optional `port`
# column; `ssh-sync.nu` reads it with `get -o` so rows without it remain valid.
def ssh-sync-list []: nothing -> table<name: string, hostname: string, user: string, private_key: string, public_key: string> {
    ssh-sync-bitwarden-require-command bw

    let current_session = ($env.BW_SESSION? | default "" | str trim)
    let initial_status = (ssh-sync-bitwarden-run-json ["status"])

    if (($initial_status | get -o status | default "") == "unauthenticated") {
        ssh-sync-bitwarden-error "Bitwarden CLI is not logged in. Run `bw login` first."
    }

    if (($current_session | is-empty) or (($initial_status | get -o status | default "") != "unlocked")) {
        let accessor_secret = (ssh-sync-bitwarden-secret-get)
        let secret = if $accessor_secret == null {
            input --suppress-output "Bitwarden master password: "
        } else {
            $accessor_secret
        }

        $env.BW_SESSION = (ssh-sync-bitwarden-unlock $secret)
    }

    let status = (ssh-sync-bitwarden-run-json ["status"])

    if (($status | get -o status | default "") != "unlocked") {
        ssh-sync-bitwarden-error $"Bitwarden vault is not unlocked; current status is '($status.status)'"
    }

    print "Syncing Bitwarden..."
    let sync_result = (^bw sync | complete)

    if $sync_result.exit_code != 0 {
        ssh-sync-bitwarden-error (
            [
                "bw sync failed"
                ($sync_result.stderr | str trim)
                ($sync_result.stdout | str trim)
            ]
            | where {|line| not ($line | is-empty) }
            | str join "\n"
        )
    }

    let folders = (ssh-sync-bitwarden-run-json ["list" "folders"])
    let ssh_folders = ($folders | where name == "SSH")

    if (($ssh_folders | length) == 0) {
        ssh-sync-bitwarden-error "No Bitwarden folder named 'SSH' was found"
    }

    if (($ssh_folders | length) > 1) {
        ssh-sync-bitwarden-error "More than one Bitwarden folder named 'SSH' was found; refusing to guess"
    }

    let folder_id = ($ssh_folders | first | get id)
    let items = (ssh-sync-bitwarden-run-json ["list" "items" "--folderid" $folder_id])

    let ssh_items = ($items | where {|item| (($item | get -o type | default 0) == 5) or (not (($item | get -o sshKey | default null) == null)) })
    mut entries = []

    for item in $ssh_items {
        let port = (ssh-sync-bitwarden-port $item)
        mut entry = {
            name: ($item | get name)
            hostname: (ssh-sync-bitwarden-field $item "Host")
            user: (ssh-sync-bitwarden-field $item "User")
            private_key: ($item | get -o sshKey.privateKey | default "")
            public_key: ($item | get -o sshKey.publicKey | default "")
        }

        if $port != null {
            $entry = ($entry | insert port $port)
        }

        $entries = ($entries | append $entry)
    }

    $entries
}
