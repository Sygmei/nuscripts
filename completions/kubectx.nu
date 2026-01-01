module "kubectx extern" {
    def complete_kubectx_contexts [] {
        kubectl config get-contexts -o name | lines
    }

    export extern kubectx [
        context: string@complete_kubectx_contexts
    ]
}

use "kubectx extern" kubectx