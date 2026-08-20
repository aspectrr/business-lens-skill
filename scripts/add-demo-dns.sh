#!/usr/bin/env bash
# Adds fly DNS records for the three demo subdomains (madcactus.org, Google Cloud DNS).
# Prereq: gcloud auth login  (then: bash scripts/add-demo-dns.sh)
set -euo pipefail

ZONE=$(gcloud dns managed-zones list --filter="dnsName=madcactus.org." --format="value(name)")
[ -n "$ZONE" ] || { echo "no madcactus.org zone found in current project"; exit 1; }
echo "zone: $ZONE"

# CNAME per subdomain -> app.fly.dev (auto-tracks fly IP changes; fly accepts CNAME for subdomains)
gcloud dns record-sets create koola.madcactus.org. --zone="$ZONE" --type=CNAME --ttl=300 --rrdatas="koola-brain.fly.dev."
gcloud dns record-sets create mo.madcactus.org. --zone="$ZONE" --type=CNAME --ttl=300 --rrdatas="mo-strategies-brain.fly.dev."
gcloud dns record-sets create flora.madcactus.org. --zone="$ZONE" --type=CNAME --ttl=300 --rrdatas="flora-brain.fly.dev."

for d in koola-brain mo-strategies-brain flora-brain; do fly certs list -a "$d" | tail -2; done
