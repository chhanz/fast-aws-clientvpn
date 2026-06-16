# AWS Client VPN Automation Tool

한국어: [README.md](README.md)

A tool that creates and tears down an AWS Client VPN with a single command. It
handles everything from certificate issuance to endpoint deployment and
generation of the client configuration file (.ovpn) in one go.

- The shell script (`mgt-clientvpn.sh`) handles certificate "creation".
- The CloudFormation template (`clientvpn.yaml`) handles the "state" of AWS resources.

Authentication uses mutual authentication (X.509 certificates where the server
and client are signed by the same CA).

## Files

| File | Description |
|------|-------------|
| `mgt-clientvpn.sh` | Integrated management script (single entry point) |
| `clientvpn.yaml`   | CloudFormation template (VPN infrastructure declaration) |
| `clientvpn.conf`   | Config file created by `configure` (you do not need to create it yourself) |

## Prerequisites

- Execution host: MacOS / Linux (bash environment)
- AWS CLI v2 installed and credentials configured (`aws configure`)
- `git` installed (easy-rsa is downloaded when generating certificates)
- Permissions required for the account in use: ACM, EC2 (Client VPN), CloudFormation
- The target VPC and subnet must exist, and an internet gateway or NAT gateway is required if external access is needed.

## Usage Order

The recommended flow is `configure` -> `deploy` -> `status` -> `gen` -> `destroy`.

### 1. configure - enter environment values

```bash
./mgt-clientvpn.sh configure
```

Interactively collects the following values and saves them to `clientvpn.conf`.

| Item | Default | Description |
|------|---------|-------------|
| Region | `ap-northeast-2` | Region to deploy into |
| VPC ID | (required) | Must start with `vpc-` |
| Subnet ID | (required) | Must start with `subnet-` |
| Client CIDR | `10.100.0.0/22` | IP range assigned to VPN clients (/12 to /22) |
| Internal network CIDR | `172.31.0.0/16` | Internal range to authorize for VPN access |
| Split Tunnel | `true` | If true, only internal network traffic goes over the VPN |
| DNS Servers | `169.254.169.253` | DNS pushed to VPN clients. The default resolves both internal and public domains (leave empty to keep the client default DNS) |

Input is validated in two stages.

- Format validation (always): VPC/Subnet ID prefixes, Client CIDR mask range (/12 to /22).
- Live validation (when permissions allow): checks that the subnet actually belongs to that VPC.
  If permission is missing, validation is skipped, a manual-check notice is shown, and it proceeds (deployment is not blocked).

### 2. deploy - deploy

```bash
./mgt-clientvpn.sh deploy                # Split Tunnel (default)
./mgt-clientvpn.sh deploy --full-tunnel  # Full Tunnel (all traffic over the VPN)
```

Sequence:

1. Looks up a certificate tagged `Name=clientvpn-server` in ACM.
2. If none exists, generates CA/server/client certificates with easy-rsa and imports them into ACM.
   (If one exists, it is reused. This tag is the sole criterion for idempotency.)
3. Deploys the VPN endpoint with CloudFormation.
4. Generates the client `.ovpn` file (under `clientvpn-certs/` in the same directory as the script).

> Split Tunnel vs Full Tunnel
> - Split (default): Only internal network (`TargetCidr`) traffic goes through the VPN; the rest goes over the normal internet connection.
> - Full: All traffic (`0.0.0.0/0`) goes over the VPN. In split mode a `0.0.0.0/0` route is
>   not created (this is intentionally blocked because it can drop connectivity).
> - Deploying in Full Tunnel automatically adds an authorization rule for internet traffic (a `0.0.0.0/0` authorization rule); without it, internet access is blocked.

### 3. status - check status

```bash
./mgt-clientvpn.sh status
```

Shows the stack status, endpoint status, associated subnets, certificate ARN, and tunnel mode.

> The Client CIDR cannot be changed after the endpoint is created. To change it, you must `destroy` and redeploy.

### 4. gen - regenerate the connection config

```bash
./mgt-clientvpn.sh gen
```

Re-downloads and regenerates the `.ovpn` file for an already deployed endpoint.

### 5. destroy - delete

```bash
./mgt-clientvpn.sh destroy
```

Proceeds only if you enter `yes`. It deletes the stack first, waits for completion, then cleans up the certificate.
(The endpoint references the certificate, so deleting out of order would cause the certificate deletion to fail.)

## Where Files Are Created

- Config file: `clientvpn.conf` in the same directory as the script
- Certificates/keys and `.ovpn`: `clientvpn-certs/` in the same directory as the script
  - Private key files are saved with permission `600`.

## Troubleshooting

| Symptom | Cause / Resolution |
|---------|--------------------|
| `Run ./mgt-clientvpn.sh configure first` | The config file is missing. Run `configure` first. |
| configure says automatic validation is skipped | No AWS CLI permission. Verify the subnet's VPC in the console, then proceed. |
| `Subnet does not belong to the given VPC` | The Subnet ID or VPC ID was entered incorrectly. Check the values. |
| Stack creation fails related to ConnectionLogOptions | The template already specifies `Enabled: false`. Check your AWS CLI/permissions. |
| No internet after deploy (Full Tunnel) | The internet authorization rule is added automatically by this tool. If it still fails, the associated subnet's route table must have a `0.0.0.0/0 -> IGW` route (public subnet) or `0.0.0.0/0 -> NAT GW` route (private subnet). This is outside the scope of this tool, so verify it beforehand. |
| Domain names do not resolve after deploy (Full Tunnel) | Check via status that the default DNS (`169.254.169.253`, AWS Route 53 Resolver) is pushed to clients. If you left it empty in configure, the client default DNS is used, which can fail to resolve under Full Tunnel. |
| Cannot reach the internal network (Split Tunnel) | Verify that `TargetCidr` matches your actual internal network range. |
| Certificate not embedded in `.ovpn` | Make sure you ran `deploy` on the host that generated the certificate. The key must exist locally to be inserted. |
| Certificate deletion fails during destroy | The endpoint still references the certificate. Confirm the stack deletion finished, then retry. |

## References

- Certificate generation uses [OpenVPN/easy-rsa](https://github.com/OpenVPN/easy-rsa).
- Clients connect using the `.ovpn` file with the AWS VPN Client or an OpenVPN-compatible client.
