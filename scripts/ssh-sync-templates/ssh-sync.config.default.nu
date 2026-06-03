# Accessor config for ssh-sync.
#
# `ssh-sync-list` return type:
#
# list<record<
#     name: string,
#     hostname: string,
#     user: string,
#     private_key: string,
#     public_key: string,
#     port?: int,
# >>
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
#
# Required fields:
# - name: SSH alias and key filename
# - hostname: real remote host
# - user: SSH user
# - private_key: private key text
# - public_key: public key text
def ssh-sync-list []: nothing -> list<record<name: string, hostname: string, user: string, private_key: string, public_key: string, port?: int>> {
    []
}

# Return type: bool
def ssh-sync-secret-store-interactive []: nothing -> bool {
    false
}

# Return type: bool
def ssh-sync-secret-store [secret: string]: nothing -> bool {
    false
}

# Return type: bool
def ssh-sync-secret-delete []: nothing -> bool {
    false
}
