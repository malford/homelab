.POSIX:

default: namespace argocd root

env ?= prod

namespace:
	kubectl create namespace argocd --dry-run=client --output=yaml \
		| kubectl apply -f -

.PHONY: argocd
argocd:
	cd argocd && ./apply.sh

.PHONY: root
root:
	cd root && ENV=${env} ./apply.sh
