# Azure HA with a bring-your-own IP and TLS on your own domain

[`../azure-ha`](../azure-ha) is the right starting point for most first
deployments. Use **this** one when any of the following is true:

- you run your own authoritative DNS and want the A record in place **before**
  the first apply, rather than reading an address off a finished apply;
- you need TLS on a custom hostname with your own certificate;
- a host-naming standard governs the VM names.

`../azure-ha` cannot do these: it passes neither `public_ip_id` nor any of the
`appgw_*` inputs, and the network module it uses creates no Application Gateway
subnet.

## Two phases, and why it cannot be one

`appgw_backend_protocol = "Https"` requires `appgw_backend_root_cert_pem`,
because Application Gateway v2 validates the backend certificate against an
uploaded trusted root and serves 502 if it is not trusted. The marketplace image
generates that certificate at **first boot**, so it cannot exist before the VMs
do.

**Phase 1** — `enable_application_gateway = false`

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in, leave the appgw_* block commented
terraform init && terraform apply
terraform output dns_target                    # == your public_ip_id address
```

The console answers on your reserved IP, so pre-registered DNS resolves
immediately. Traffic path: `443` on the reserved IP → load balancer → VM `3333`
over TLS, presenting the image's first-boot self-signed certificate. That is
HTTPS end to end; browsers warn because the certificate is not yours yet.

**Phase 2** — read the backend certificate, then enable the gateway

```bash
az vm run-command invoke -g <rg> -n <vm-name> --command-id RunShellScript \
  --scripts 'cat /opt/hailbytes-sat/hailbytes-sat-admin.crt' \
  --query 'value[0].message' -o tsv
```

The VMs have no public IP and the NSG opens no SSH, so `az vm run-command` via
the Azure agent is the route in. Put that certificate in
`appgw_backend_root_cert_pem`, set the PFX values, flip the flag, apply.

```bash
terraform apply
terraform output dns_target                    # a DIFFERENT address -- move DNS
```

## Three things that bite

**The gateway has its own address.** `public_ip_id` fronts the load balancer;
once the gateway is enabled it is the front door and the load balancer becomes an
internal hop. `dns_target` changes between phases. Set `appgw_public_ip_id` to a
second reserved IP if you want that address pinned in advance too — otherwise
DNS moves on the phase 2 apply.

**Azure refuses a password-less PFX.** Several export paths produce one (an
Azure App Service Certificate exports with an empty password). Add one:

```bash
openssl pkcs12 -in in.pfx -nodes -passin pass: -out tmp.pem
openssl pkcs12 -export -in tmp.pem -out out.pfx -passout pass:<password>
base64 -w0 out.pfx
```

**Port 80 is not the console.** SAT binds the admin console on **3333 over
TLS**; 80 is the **phishing server**. The tier module defaults to `Http`/`80`,
which suits other topologies — point the gateway there and it returns a healthy
`200` serving landing pages where you expect the console. This quickstart
defaults to `Https`/`3333` for that reason. ASM binds admin on 443.

## Key Vault access

The apply identity gets Key Vault Secrets Officer, and each VM reads its own
secrets through its managed identity — so the running deployment depends on
neither a person nor a service principal. When the apply runs **as a service
principal**, no human can read or rotate the database password or session keys
until you grant one. No re-apply needed:

```bash
az role assignment create --role "Key Vault Secrets User" \
  --assignee <upn-or-object-id> --scope "$(terraform output -raw key_vault_id)"
```

Or set `key_vault_reader_principal_ids` at deploy time — a group is better than
individuals, since membership then changes without a Terraform run.

## Cost

The Application Gateway adds roughly **$187/mo**, or **~$336/mo** with a WAF
policy attached, on top of the load balancer, which stays in the topology.
See [COST_SHAPES.md](../../COST_SHAPES.md) and
[AZURE_COST_SHAPES.md](../../AZURE_COST_SHAPES.md).
