#!/bin/sh

VALUES="values.yaml"

kubectl get ingress gitea --namespace gitea \
    || VALUES="values-seed.yaml"

helm template \
    --include-crds \
    --namespace argocd \
    --values "${VALUES}" \
    --values "values-${ENV}.yaml" \
    argocd . \
    | kubectl apply -n argocd -f -
