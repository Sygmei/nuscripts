module "zoxide extern" {
    def complete_zoxide_opt [] {
        zoxide query --list | each { |path| $path | path basename | str trim } | filter {|zopt| $zopt | is-empty | not $in }
    }

    export extern z [
        opt: string@complete_zoxide_opt
    ]
}

use "zoxide extern" z
