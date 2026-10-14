.NOTPARALLEL:
.PHONY: prototype-local prototype-validate prototype-recovery prototype-recovery-interactive prototype-broker prototype-investigation prototype-dispatch prototype-artifacts prototype-konflux prototype-runtime prototype-vm prototype-composed prototype-source-entry prototype-results prototype-all

PROTOTYPE_KUBECONFIG ?= /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig
PROTOTYPE_CONTEXT ?= kind-konflux-sandbox-prototype

prototype-local: prototype-recovery prototype-broker prototype-investigation

prototype-validate:
	bash prototypes/validate.sh

prototype-recovery:
	go -C prototypes run ./recovery

prototype-recovery-interactive:
	go -C prototypes run ./recovery -interactive

prototype-broker:
	go -C prototypes run ./broker

prototype-investigation:
	go -C prototypes run ./investigation

prototype-dispatch:
	$(MAKE) -C prototypes/dispatch run KUBECONFIG="$(PROTOTYPE_KUBECONFIG)" KUBE_CONTEXT="$(PROTOTYPE_CONTEXT)"

prototype-artifacts:
	$(MAKE) -C prototypes/artifacts run KUBECONFIG="$(PROTOTYPE_KUBECONFIG)" KUBE_CONTEXT="$(PROTOTYPE_CONTEXT)"

prototype-konflux:
	$(MAKE) -C prototypes/konflux run KUBECONFIG="$(PROTOTYPE_KUBECONFIG)" KUBE_CONTEXT="$(PROTOTYPE_CONTEXT)"

prototype-runtime:
	$(MAKE) -C prototypes/runtime run KUBECONFIG="$(PROTOTYPE_KUBECONFIG)" CLUSTER=konflux-sandbox-prototype

prototype-vm:
	$(MAKE) -C prototypes/runtime vm-run tekton-install tekton-test

prototype-composed:
	$(MAKE) -C prototypes/runtime composed

prototype-source-entry:
	$(MAKE) -C prototypes/source-entry run KUBECONFIG="$(PROTOTYPE_KUBECONFIG)" KUBE_CONTEXT="$(PROTOTYPE_CONTEXT)"

prototype-results:
	$(MAKE) -C prototypes/results run KUBECONFIG="$(PROTOTYPE_KUBECONFIG)" KUBE_CONTEXT="$(PROTOTYPE_CONTEXT)"

prototype-all: prototype-local prototype-artifacts prototype-konflux prototype-dispatch prototype-runtime prototype-vm prototype-composed prototype-source-entry prototype-results
