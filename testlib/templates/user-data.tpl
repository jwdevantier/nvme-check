#cloud-config
users:
  - name: root
    lock_passwd: false
    hashed_passwd: {{ root_password_hash }}
    ssh_authorized_keys:
      - {{ ssh_public_key }}

disable_root: false
ssh_pwauth: true

# Ubuntu package names (both arches use the Ubuntu cloud image).
packages:
  - pciutils
  - nvme-cli
  - fio

power_state:
  mode: poweroff
  # TCG s390 makes a long pre-poweroff delay pure waste; 30s is plenty.
  timeout: 30
  condition: True
