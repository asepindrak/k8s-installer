# k8s-installer

Automated installer scripts for setting up a single-node control plane (master) and worker nodes using **kubeadm** and **containerd** on Ubuntu servers.

This repo contains:
- `scripts/common.sh` - shared helper functions and package installation steps
- `scripts/master.sh` - run on the **master** node (runs `kubeadm init`, installs CNI, and writes a join command)
- `scripts/worker.sh` - run on **worker** nodes (accepts a `JOIN_COMMAND` string or parameters)
- `scripts/fetch-join.sh` - optional helper to fetch the saved join command from the master via `scp` (requires SSH access)
- `examples/kubeadm-config.yaml.example` - example kubeadm config for customization

## Quick usage

### 1) Prepare all nodes
- Ubuntu 20.04 / 22.04 / 24.04 recommended
- Ensure you can `sudo` on the target accounts and that nodes can reach each other (control-plane IP reachable by workers)
- Disable swap (scripts will attempt to disable it)

### 2) On master node
Copy `scripts/master.sh` to the master server and run:

```bash
chmod +x master.sh
sudo ./master.sh
```

At the end, the script will print and save a `kubeadm join ...` command to `/root/kubeadm-join.sh`. You can copy that string to worker nodes.

If you want the join command in one line:
```bash
sudo cat /root/kubeadm-join.sh
```

### 3) On worker nodes
Method A — use the join command string:
```bash
# example:
sudo ./worker.sh --join "$(cat /root/kubeadm-join.sh)"
```

Method B — pass token, master IP, and discovery hash:
```bash
sudo ./worker.sh --token <token> --master-ip <master-ip>:6443 --discovery-hash sha256:<hash>
```

Method C — use `fetch-join.sh` to scp the join script from master (requires SSH keys and access):
```bash
./fetch-join.sh ubuntu@master.example.com:/root/kubeadm-join.sh
sudo ./worker.sh --join "$(cat kubeadm-join.sh)"
```

### 4) After workers joined
On master:
```bash
kubectl get nodes
```

## Notes & Security
- The scripts are intended for automation and testing. Review before running in production.
- The master saves the join command to `/root/kubeadm-join.sh` — secure that file or remove after use.
- For production, consider using a more secure workflow (Vault for tokens, ephemeral tokens, automation with Ansible, etc.)

