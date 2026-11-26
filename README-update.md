## HTTPS, domain and certificate

The public hostname is controlled by one variable, `domain`, set in `terraform.tfvars`.

```hcl
domain = "136-81-131-55.sslip.io"   # test domain; replace with your own before go-live
```

- The test domain is an [sslip.io](https://sslip.io) hostname. It resolves to the IP inside the name, so no DNS record is needed.
- The load balancer IP is `136.81.131.55` (forwarding rules `shop-prod-http` and `shop-prod-https`). It must stay a reserved static address, or the hostname and certificate break.
- The certificate is a Google-managed SSL certificate (free). It only becomes `ACTIVE` when the domain resolves to the load balancer IP.
- `example.com` domains can never be validated. Do not use them.

### Certificate resource (`lb.tf`)

```hcl
resource "google_compute_managed_ssl_certificate" "cert" {
  name = "shop-prod-cert-${substr(md5(var.domain), 0, 6)}"

  managed {
    domains = [var.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

- The name includes a hash of the domain, so changing `domain` creates a new certificate with a new name.
- `create_before_destroy` makes Terraform create the new certificate and attach it to the HTTPS proxy before deleting the old one. Managed certificates are immutable and cannot be deleted while a proxy uses them.
- Provisioning takes about 15 to 60 minutes after DNS resolves.

### Changing the domain

1. Point an A record for the new hostname at `136.81.131.55` (skip for sslip.io / nip.io).
2. Set `domain` in `terraform.tfvars`.
3. `terraform plan`. Expect: new certificate created, HTTPS proxy updated, old certificate destroyed, uptime check replaced.
4. `terraform apply`.
5. Wait for the certificate to become `ACTIVE`:
   ```bash
   gcloud compute ssl-certificates list
   gcloud compute ssl-certificates describe <cert-name> --global \
     --format="get(managed.status,managed.domainStatus)"
   ```
6. Verify: `curl -I https://<domain>` (on Windows add `--ssl-no-revoke`).

## Monitoring (`monitoring.tf`)

The uptime check `google_monitoring_uptime_check_config.https` uses `var.domain` as its host, so a domain change replaces it. It has `create_before_destroy = true`. The `uptime` alert policy references the check through `uptime_check_id`, so Terraform creates the new check, repoints the alert policy, and only then deletes the old check. Without this, GCP rejects the delete because an alert policy still uses the check.

While a new certificate is provisioning, the uptime alert may fire. It clears once the certificate is `ACTIVE`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Error 409 ... shop-prod-cert already exists` on apply | Certificate exists in GCP but not in state, or a name clash during replacement | `terraform state show` to see what is tracked; import with the exact ID or delete the unused orphan; keep the hashed name and `create_before_destroy` |
| `Resource already managed by Terraform` on import | The address already has a state entry | Do not import; inspect with `terraform state show`, or `terraform state rm` first |
| Certificate `PROVISIONING_FAILED` | Domain is not valid or not reachable (e.g. `example.com`) | Use a real domain, or an sslip.io / nip.io name for tests |
| `FAILED_NOT_VISIBLE` | DNS does not point at the LB IP, DNS proxy (e.g. Cloudflare orange cloud) enabled, or CAA blocks `pki.goog` | Fix the A record, disable the proxy, allow `pki.goog` in CAA |
| `Error 400 ... Alert Policies are deleted` (uptime check) | Check replaced while an alert policy still references it | `create_before_destroy` on the uptime check (already set) |
| TLS handshake fails right after `ACTIVE` | Certificate still propagating, or Windows schannel revocation check | Wait 5 to 15 minutes; use `curl --ssl-no-revoke` |

## Go-live checklist

- [ ] Replace the sslip.io domain with a domain you own (A record to `136.81.131.55`, then update `domain`).
- [ ] Confirm the IP is reserved: `gcloud compute addresses list --global`.
- [ ] Remote Terraform state with locking, so state and real resources cannot drift.
- [ ] Redirect HTTP (port 80) to HTTPS on the `shop-prod-http` forwarding rule or URL map.
- [ ] Check the HTTPS proxy SSL policy (minimum TLS version).
- [ ] Confirm `terraform plan` shows "No changes".
- [ ] Confirm all alert policies are healthy and notification channels are correct.
