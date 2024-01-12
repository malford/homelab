.POSIX:

env ?= prod
export KUBECONFIG = $(shell pwd)/kubeconfig-${env}.yaml

ifeq ($(env), dev)
k3d:
	k3d cluster start homelab-${env} || k3d cluster create --config k3d-${env}.yaml
	k3d kubeconfig get homelab-${env} > kubeconfig-${env}.yaml
else
default: boot cluster

~/.ssh/id_ed25519:
	ssh-keygen -t ed25519 -P '' -f "$@"

boot: ~/.ssh/id_ed25519
	ansible-playbook \
		--inventory inventories/${env}.yml \
		boot.yml

cluster:
	ansible-playbook \
		--inventory inventories/${env}.yml \
		cluster.yml

console:
	ansible-console \
		--inventory inventories/${env}.yml
endif
