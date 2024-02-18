.POSIX:

default: namespace argocd root

namespace:
	kubectl create namespace argocd --dry-run=client --output=yaml | kubectl apply -f -

.PHONY: argocd
argocd:
	kubectl get customresourcedefinitions.apiextensions.k8s.io applications.argoproj.io applicationsets.argoproj.io > /dev/null || kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml && cd argocd && ./apply.sh

.PHONY: root
root:
	cd root && ./apply.sh
