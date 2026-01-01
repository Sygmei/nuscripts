module "kubens extern" {
    def complete_kubens_namespaces [] {
        kubectl get namespaces -o jsonpath="{.items[*].metadata.name}" | split row " "
    }

    export extern kubens [
        namespace: string@complete_kubens_namespaces
    ]
}

use "kubens extern" kubens