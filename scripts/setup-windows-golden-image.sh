#!/bin/bash
set -euo pipefail

#
# Windows Server 2022 Golden Image Setup for cloud29 (bare-metal)
#
# Runs locally; all cluster operations execute via ssh cloud29.
# Creates a sysprepped golden image PVC with Python workloads
# (file-writer, sqlite-writer, http-server) on the blue (source) cluster.
#
# Prerequisites:
#   - SSH access to cloud29 bastion
#   - Windows Server 2022 ISO at /tmp/win2022.iso on the bastion
#   - VirtIO driver container image available in cluster
#

BASTION="cloud29"
KUBECONFIG_PATH="/root/blue/kubeconfig"
NS="windows-golden-images"
VM_NAME="win2022-installer"
GOLDEN_PVC="win2022-golden"
ROOT_DISK_SC="hostpath-csi"
ISO_SC="localblock-sc"
ROOT_DISK_SIZE="40Gi"
ISO_PVC_NAME="win2022-iso"
ISO_SIZE="6Gi"
ISO_PATH="/tmp/win2022.iso"
PIN_NODE="d39-h05-000-r660"
ADMIN_PASS="admin123!"

VIRTIO_IMAGE_FALLBACK="registry.redhat.io/container-native-virtualization/virtio-win-rhel9@sha256:cc98b37978b84b5fe7127c08d52a09c8c136c61ae51085a3f3180e3e11275497"

bastion() {
  ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH $*"
}

confirm() {
  echo ""
  read -rp "Press Enter to continue (Ctrl-C to abort)... "
  echo ""
}

get_pod_name() {
  bastion "oc get pods -n ${NS} -l kubevirt.io/vm=${VM_NAME} -o jsonpath='{.items[0].metadata.name}'"
}

get_domain_name() {
  local pod="$1"
  ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc exec ${pod} -n ${NS} -c compute -- virsh -c qemu:///session list --name" | head -1
}

guest_exec() {
  local pod="$1" domain="$2" script_path="$3" script_content="$4"
  local b64
  b64=$(echo "$script_content" | base64)

  local handle
  handle=$(ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc exec ${pod} -n ${NS} -c compute -- virsh -c qemu:///session qemu-agent-command ${domain} '{\"execute\":\"guest-file-open\",\"arguments\":{\"path\":\"${script_path}\",\"mode\":\"w\"}}'" | jq -r '.return')

  ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc exec ${pod} -n ${NS} -c compute -- virsh -c qemu:///session qemu-agent-command ${domain} '{\"execute\":\"guest-file-write\",\"arguments\":{\"handle\":${handle},\"buf-b64\":\"${b64}\"}}'" >/dev/null

  ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc exec ${pod} -n ${NS} -c compute -- virsh -c qemu:///session qemu-agent-command ${domain} '{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":${handle}}}'" >/dev/null

  local pid
  pid=$(ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc exec ${pod} -n ${NS} -c compute -- virsh -c qemu:///session qemu-agent-command ${domain} '{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-ExecutionPolicy\",\"Bypass\",\"-File\",\"${script_path}\"],\"capture-output\":true}}'" | jq -r '.return.pid')

  sleep 10

  local result
  result=$(ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc exec ${pod} -n ${NS} -c compute -- virsh -c qemu:///session qemu-agent-command ${domain} '{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}'" 2>/dev/null || echo '{}')

  local exited
  exited=$(echo "$result" | jq -r '.return.exited // false')
  if [[ "$exited" != "true" ]]; then
    echo "  Script still running (PID ${pid}), waiting 30 more seconds..."
    sleep 30
    result=$(ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc exec ${pod} -n ${NS} -c compute -- virsh -c qemu:///session qemu-agent-command ${domain} '{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}'" 2>/dev/null || echo '{}')
  fi

  local stdout stderr exitcode
  stdout=$(echo "$result" | jq -r '.return["out-data"] // ""' | base64 -d 2>/dev/null || true)
  stderr=$(echo "$result" | jq -r '.return["err-data"] // ""' | base64 -d 2>/dev/null || true)
  exitcode=$(echo "$result" | jq -r '.return.exitcode // "unknown"')

  echo "$stdout"
  if [[ -n "$stderr" ]]; then
    echo "  STDERR: $stderr" >&2
  fi
  return 0
}

echo "============================================"
echo " Windows Server 2022 Golden Image Setup"
echo " Target: cloud29 blue cluster (source)"
echo " Root disk: ${ROOT_DISK_SC}"
echo " ISO: ${ISO_SC} (Block mode)"
echo " Pinned to: ${PIN_NODE}"
echo "============================================"
echo ""

# ──────────────────────────────────────────────
# Step 1: Create namespace
# ──────────────────────────────────────────────
echo "[1/12] Creating namespace ${NS}..."
bastion "oc create namespace ${NS} --dry-run=client -o yaml | oc apply -f -"
echo "  OK"

# ──────────────────────────────────────────────
# Step 2: Discover VirtIO driver image
# ──────────────────────────────────────────────
echo ""
echo "[2/12] Discovering VirtIO driver image from cluster CNV..."
VIRTIO_IMAGE=""

VIRTIO_IMAGE=$(ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc get csv -n openshift-cnv -o json 2>/dev/null" \
  | jq -r '[.items[].spec.relatedImages[]? | select(.name | test("virtio-win"))] | .[0].image // empty' 2>/dev/null || true)

if [[ -z "$VIRTIO_IMAGE" ]]; then
  echo "  CSV query returned nothing, trying HyperConverged CR..."
  VIRTIO_IMAGE=$(ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o json 2>/dev/null" \
    | jq -r '.status.relatedObjects[]? | select(.name | test("virtio")) | .name // empty' 2>/dev/null || true)
fi

if [[ -z "$VIRTIO_IMAGE" ]]; then
  echo "  Could not auto-discover, using fallback image"
  VIRTIO_IMAGE="$VIRTIO_IMAGE_FALLBACK"
fi
echo "  VirtIO image: ${VIRTIO_IMAGE}"

# ──────────────────────────────────────────────
# Step 3: Create ISO PVC (localblock-sc Block mode + dd)
# ──────────────────────────────────────────────
echo ""
echo "[3/12] Creating ISO PVC (${ISO_SC} Block mode)..."
echo "  ISO must already exist at ${ISO_PATH} on the bastion."
echo ""

if ! ssh "$BASTION" "test -f ${ISO_PATH}"; then
  echo "  ERROR: ISO not found at ${ISO_PATH} on ${BASTION}"
  echo "  Download it first:"
  echo "    ssh ${BASTION} 'curl -Lo ${ISO_PATH} https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso'"
  exit 1
fi

ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc apply -f -" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${ISO_PVC_NAME}
  namespace: ${NS}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${ISO_SIZE}
  storageClassName: ${ISO_SC}
  volumeMode: Block
EOF

echo "  PVC created. Waiting for it to bind..."
bastion "oc wait pvc ${ISO_PVC_NAME} -n ${NS} --for=jsonpath='{.status.phase}'=Bound --timeout=2m" || {
  echo "  PVC not bound yet. It uses WaitForFirstConsumer — will bind when a pod mounts it."
  echo "  Proceeding with dd copy via helper pod..."
}

echo "  Copying ISO to PVC via dd..."
ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc apply -f -" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: iso-writer
  namespace: ${NS}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${PIN_NODE}
  restartPolicy: Never
  containers:
    - name: writer
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sleep", "3600"]
      volumeDevices:
        - name: iso
          devicePath: /dev/block-device
  volumes:
    - name: iso
      persistentVolumeClaim:
        claimName: ${ISO_PVC_NAME}
EOF

echo "  Waiting for helper pod..."
bastion "oc wait pod iso-writer -n ${NS} --for=condition=Ready --timeout=5m"

echo "  Writing ISO to block device (this takes a few minutes)..."
ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc exec iso-writer -n ${NS} -- dd if=/dev/zero of=/dev/block-device bs=1M count=1" >/dev/null 2>&1 || true
ssh "$BASTION" "cat ${ISO_PATH} | KUBECONFIG=$KUBECONFIG_PATH oc exec -i iso-writer -n ${NS} -- dd of=/dev/block-device bs=4M"

echo "  Cleaning up helper pod..."
bastion "oc delete pod iso-writer -n ${NS} --wait=true"
echo "  ISO written to PVC"

# ──────────────────────────────────────────────
# Step 4: Create sysprep secret (NO auto-sysprep)
# ──────────────────────────────────────────────
echo ""
echo "[4/12] Creating sysprep secret for unattended installation..."
echo "  NOTE: Sysprep is NOT in FirstLogonCommands — workloads must be installed first."

ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc apply -f -" <<'SYSPREP_EOF'
apiVersion: v1
kind: Secret
metadata:
  name: win2022-installer-sysprep
  namespace: windows-golden-images
type: Opaque
stringData:
  autounattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <SetupUILanguage>
            <UILanguage>en-US</UILanguage>
          </SetupUILanguage>
          <InputLocale>en-US</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-PnpCustomizationsWinPE"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1">
              <Path>E:\amd64\w11</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2">
              <Path>E:\viostor\w11\amd64</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="3">
              <Path>E:\NetKVM\w11\amd64</Path>
            </PathAndCredentials>
          </DriverPaths>
        </component>
        <component name="Microsoft-Windows-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <DiskConfiguration>
            <Disk wcm:action="add">
              <CreatePartitions>
                <CreatePartition wcm:action="add">
                  <Order>1</Order>
                  <Type>EFI</Type>
                  <Size>100</Size>
                </CreatePartition>
                <CreatePartition wcm:action="add">
                  <Order>2</Order>
                  <Type>MSR</Type>
                  <Size>128</Size>
                </CreatePartition>
                <CreatePartition wcm:action="add">
                  <Order>3</Order>
                  <Type>Primary</Type>
                  <Extend>true</Extend>
                </CreatePartition>
              </CreatePartitions>
              <ModifyPartitions>
                <ModifyPartition wcm:action="add">
                  <Order>1</Order>
                  <PartitionID>1</PartitionID>
                  <Format>FAT32</Format>
                  <Label>EFI</Label>
                </ModifyPartition>
                <ModifyPartition wcm:action="add">
                  <Order>2</Order>
                  <PartitionID>2</PartitionID>
                </ModifyPartition>
                <ModifyPartition wcm:action="add">
                  <Order>3</Order>
                  <PartitionID>3</PartitionID>
                  <Format>NTFS</Format>
                  <Label>Windows</Label>
                </ModifyPartition>
              </ModifyPartitions>
              <DiskID>0</DiskID>
              <WillWipeDisk>true</WillWipeDisk>
            </Disk>
          </DiskConfiguration>
          <ImageInstall>
            <OSImage>
              <InstallFrom>
                <MetaData wcm:action="add">
                  <Key>/IMAGE/INDEX</Key>
                  <Value>2</Value>
                </MetaData>
              </InstallFrom>
              <InstallTo>
                <DiskID>0</DiskID>
                <PartitionID>3</PartitionID>
              </InstallTo>
            </OSImage>
          </ImageInstall>
          <UserData>
            <AcceptEula>true</AcceptEula>
            <ProductKey>
              <WillShowUI>OnError</WillShowUI>
            </ProductKey>
          </UserData>
        </component>
      </settings>
      <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS">
          <ComputerName>WIN2022-GOLD</ComputerName>
          <TimeZone>UTC</TimeZone>
        </component>
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS">
          <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Networking-MPSSVC-Svc"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <FirewallGroups>
            <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
              <Active>true</Active>
              <Group>Remote Desktop</Group>
              <Profile>all</Profile>
            </FirewallGroup>
          </FirewallGroups>
        </component>
      </settings>
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideLocalAccountScreen>true</HideLocalAccountScreen>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <ProtectYourPC>3</ProtectYourPC>
          </OOBE>
          <UserAccounts>
            <AdministratorPassword>
              <Value>admin123!</Value>
              <PlainText>true</PlainText>
            </AdministratorPassword>
            <LocalAccounts>
              <LocalAccount wcm:action="add">
                <Name>admin</Name>
                <Group>Administrators</Group>
                <Password>
                  <Value>admin123!</Value>
                  <PlainText>true</PlainText>
                </Password>
              </LocalAccount>
            </LocalAccounts>
          </UserAccounts>
          <AutoLogon>
            <Enabled>true</Enabled>
            <Username>admin</Username>
            <Password>
              <Value>admin123!</Value>
              <PlainText>true</PlainText>
            </Password>
            <LogonCount>1</LogonCount>
          </AutoLogon>
          <FirstLogonCommands>
            <SynchronousCommand wcm:action="add">
              <Order>1</Order>
              <CommandLine>powershell -Command "Set-ExecutionPolicy RemoteSigned -Force"</CommandLine>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>2</Order>
              <CommandLine>powershell -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck"</CommandLine>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>3</Order>
              <CommandLine>powershell -Command "Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"</CommandLine>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>4</Order>
              <CommandLine>powershell -Command "Install-WindowsFeature -Name NET-Framework-45-Core"</CommandLine>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>5</Order>
              <CommandLine>E:\virtio-win-guest-tools.exe /install /passive /norestart</CommandLine>
              <Description>Install virtio-win guest tools (QEMU guest agent + drivers)</Description>
            </SynchronousCommand>
          </FirstLogonCommands>
        </component>
      </settings>
    </unattend>
SYSPREP_EOF
echo "  OK"

# ──────────────────────────────────────────────
# Step 5: Create installer VM
# ──────────────────────────────────────────────
echo ""
echo "[5/12] Creating Windows installer VM..."

ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc apply -f -" <<VMEOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NS}
  labels:
    app: win2022-installer
spec:
  runStrategy: RerunOnFailure
  dataVolumeTemplates:
    - metadata:
        name: ${VM_NAME}-rootdisk
      spec:
        pvc:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: ${ROOT_DISK_SIZE}
          storageClassName: ${ROOT_DISK_SC}
        source:
          blank: {}
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${VM_NAME}
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${PIN_NODE}
      domain:
        clock:
          timer:
            hpet:
              present: false
            pit:
              tickPolicy: delay
            rtc:
              tickPolicy: catchup
            hyperv: {}
          utc: {}
        cpu:
          cores: 4
        features:
          acpi: {}
          apic: {}
          hyperv:
            relaxed: {}
            vapic: {}
            spinlocks:
              spinlocks: 8191
            vpindex: {}
            runtime: {}
            synic: {}
            stimer:
              direct: {}
            reset: {}
            frequencies: {}
            reenlightenment: {}
            tlbflush: {}
            ipi: {}
          smm:
            enabled: true
        firmware:
          bootloader:
            efi:
              secureBoot: true
        machine:
          type: q35
        devices:
          disks:
            - disk:
                bus: sata
              name: rootdisk
              bootOrder: 2
            - cdrom:
                bus: sata
              name: iso
              bootOrder: 1
            - cdrom:
                bus: sata
              name: virtiocontainerdisk
            - cdrom:
                bus: sata
              name: sysprep
          interfaces:
            - name: default
              masquerade: {}
              model: virtio
        resources:
          requests:
            memory: 8Gi
      networks:
        - name: default
          pod: {}
      terminationGracePeriodSeconds: 3600
      volumes:
        - name: rootdisk
          dataVolume:
            name: ${VM_NAME}-rootdisk
        - name: iso
          persistentVolumeClaim:
            claimName: ${ISO_PVC_NAME}
        - name: virtiocontainerdisk
          containerDisk:
            image: ${VIRTIO_IMAGE}
        - name: sysprep
          sysprep:
            secret:
              name: win2022-installer-sysprep
VMEOF
echo "  OK"

# ──────────────────────────────────────────────
# Step 6: Wait for Windows installation
# ──────────────────────────────────────────────
echo ""
echo "[6/12] Windows installation in progress..."
echo ""
echo "  IMPORTANT: UEFI may not auto-boot from ISO. If the VM sits at the firmware"
echo "  setup menu, you need to navigate Boot Manager via virsh send-key:"
echo ""
echo "    POD=\$(ssh ${BASTION} 'KUBECONFIG=${KUBECONFIG_PATH} oc get pods -n ${NS} -l kubevirt.io/vm=${VM_NAME} -o name')"
echo "    ssh ${BASTION} \"KUBECONFIG=${KUBECONFIG_PATH} oc exec \$POD -n ${NS} -c compute -- virsh -c qemu:///session send-key ${VM_NAME} KEY_DOWN KEY_DOWN KEY_DOWN\""
echo "    # Then KEY_UP to select DVD, KEY_ENTER to boot"
echo ""
echo "  Monitor with VNC:"
echo "    ssh -L 5900:localhost:5900 ${BASTION} 'KUBECONFIG=${KUBECONFIG_PATH} virtctl vnc ${VM_NAME} -n ${NS} --proxy-only --port 5900'"
echo ""
echo "  The unattended install takes approximately 20-30 minutes."
echo "  VirtIO tools install and first logon commands run automatically."
echo "  The VM will be at the desktop when install is complete."
echo ""
echo "  Wait for the QEMU guest agent to respond, then press Enter."
confirm

# ──────────────────────────────────────────────
# Step 7: Install Python and workloads via guest agent
# ──────────────────────────────────────────────
echo ""
echo "[7/12] Installing Python and workloads via QEMU guest agent..."

POD=$(get_pod_name)
DOMAIN=$(get_domain_name "$POD")
echo "  Pod: ${POD}"
echo "  Domain: ${DOMAIN}"

SETUP_SCRIPT='[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "=== Installing Python ==="
Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.4/python-3.12.4-amd64.exe" -OutFile "$env:TEMP\python.exe"
Start-Process -Wait "$env:TEMP\python.exe" "/quiet InstallAllUsers=1 PrependPath=1"
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine")

Write-Host "=== Creating workload directories ==="
New-Item -ItemType Directory -Force -Path C:\workloads | Out-Null
New-Item -ItemType Directory -Force -Path C:\data\test | Out-Null

Write-Host "=== Writing file-writer.py ==="
@"
import time, os, datetime
LOG = r"C:\data\test\log.txt"
os.makedirs(os.path.dirname(LOG), exist_ok=True)
while True:
    with open(LOG, "a") as f:
        f.write(f"{datetime.datetime.now().isoformat()} heartbeat\n")
    time.sleep(1)
"@ | Set-Content -Path C:\workloads\file-writer.py -Encoding UTF8

Write-Host "=== Writing sqlite-writer.py ==="
@"
import time, sqlite3, os, datetime
DB = r"C:\data\test\test.db"
os.makedirs(os.path.dirname(DB), exist_ok=True)
conn = sqlite3.connect(DB)
conn.execute("CREATE TABLE IF NOT EXISTS heartbeats (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT)")
conn.commit()
while True:
    conn.execute("INSERT INTO heartbeats (ts) VALUES (?)", (datetime.datetime.now().isoformat(),))
    conn.commit()
    time.sleep(2)
"@ | Set-Content -Path C:\workloads\sqlite-writer.py -Encoding UTF8

Write-Host "=== Writing http-server.py ==="
@"
import http.server, os
os.chdir(r"C:\data")
http.server.HTTPServer(("0.0.0.0", 8080), http.server.SimpleHTTPRequestHandler).serve_forever()
"@ | Set-Content -Path C:\workloads\http-server.py -Encoding UTF8

Write-Host "=== Writing start-workloads.ps1 ==="
@"
Start-Process -WindowStyle Hidden -FilePath python -ArgumentList "C:\workloads\file-writer.py"
Start-Process -WindowStyle Hidden -FilePath python -ArgumentList "C:\workloads\sqlite-writer.py"
Start-Process -WindowStyle Hidden -FilePath python -ArgumentList "C:\workloads\http-server.py"
"@ | Set-Content -Path C:\workloads\start-workloads.ps1 -Encoding UTF8

Write-Host "=== Registering Scheduled Task ==="
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\workloads\start-workloads.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "StartWorkloads" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

Write-Host "=== Starting workloads now ==="
& C:\workloads\start-workloads.ps1
Start-Sleep -Seconds 5

Write-Host "=== Setup complete ==="'

echo "  Pushing setup script..."
guest_exec "$POD" "$DOMAIN" 'C:\setup-workloads.ps1' "$SETUP_SCRIPT"
echo "  Workload setup complete"

# ──────────────────────────────────────────────
# Step 8: Verify workloads
# ──────────────────────────────────────────────
echo ""
echo "[8/12] Verifying workloads..."
echo "  Waiting 15 seconds for workloads to generate data..."
sleep 15

VERIFY_SCRIPT='$ok = $true

Write-Host "=== File Writer ==="
if (Test-Path C:\data\test\log.txt) {
    $lines = (Get-Content C:\data\test\log.txt | Measure-Object -Line).Lines
    Write-Host "  Lines: $lines"
    if ($lines -lt 5) { Write-Host "  WARN: low line count"; $ok = $false }
} else { Write-Host "  FAIL: log.txt not found"; $ok = $false }

Write-Host "=== SQLite Writer ==="
if (Test-Path C:\data\test\test.db) {
    $pyCmd = "import sqlite3; conn=sqlite3.connect(r''C:\data\test\test.db''); print(conn.execute(''SELECT COUNT(*) FROM heartbeats'').fetchone()[0])"
    $rows = & python -c $pyCmd 2>$null
    Write-Host "  Rows: $rows"
    if ([int]$rows -lt 3) { Write-Host "  WARN: low row count"; $ok = $false }
} else { Write-Host "  FAIL: test.db not found"; $ok = $false }

Write-Host "=== HTTP Server ==="
try {
    $r = Invoke-WebRequest -Uri http://localhost:8080 -UseBasicParsing -TimeoutSec 5
    Write-Host "  Status: $($r.StatusCode)"
    if ($r.StatusCode -ne 200) { $ok = $false }
} catch { Write-Host "  FAIL: $($_.Exception.Message)"; $ok = $false }

Write-Host "=== Scheduled Task ==="
$task = Get-ScheduledTask -TaskName "StartWorkloads" -ErrorAction SilentlyContinue
if ($task) { Write-Host "  State: $($task.State)" } else { Write-Host "  FAIL: not found"; $ok = $false }

if ($ok) { Write-Host "`nAll checks PASSED" } else { Write-Host "`nSome checks FAILED" }'

guest_exec "$POD" "$DOMAIN" 'C:\verify.ps1' "$VERIFY_SCRIPT"
echo ""
echo "  Review the output above. If all checks passed, press Enter to continue."
echo "  If something failed, fix it manually then press Enter."
confirm

# ──────────────────────────────────────────────
# Step 9: Reboot test
# ──────────────────────────────────────────────
echo ""
echo "[9/12] Reboot test — verifying workloads survive restart..."

bastion "virtctl restart ${VM_NAME} -n ${NS}"
echo "  Restart triggered. Waiting 90 seconds for reboot + workload startup..."
sleep 90

POD=$(get_pod_name)
DOMAIN=$(get_domain_name "$POD")
echo "  Pod: ${POD}"
echo "  Domain: ${DOMAIN}"
echo "  Running verify again..."

guest_exec "$POD" "$DOMAIN" 'C:\verify.ps1' "$VERIFY_SCRIPT"
echo ""
echo "  Review results. Press Enter to proceed to sysprep."
confirm

# ──────────────────────────────────────────────
# Step 10: Remove Edge + Sysprep
# ──────────────────────────────────────────────
echo ""
echo "[10/12] Preparing for sysprep..."

echo "  Switching to runStrategy: Manual (prevents auto-restart after sysprep shutdown)..."
bastion "oc patch vm ${VM_NAME} -n ${NS} --type merge -p '{\"spec\":{\"runStrategy\":\"Manual\"}}'"

SYSPREP_SCRIPT='Write-Host "=== Removing Microsoft Edge (blocks sysprep) ==="
Get-AppxPackage -AllUsers *MicrosoftEdge.Stable* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

Write-Host "=== Running sysprep ==="
& C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
Write-Host "Sysprep started — VM will shut down when complete"'

echo "  Running Edge removal + sysprep..."
guest_exec "$POD" "$DOMAIN" 'C:\run-sysprep.ps1' "$SYSPREP_SCRIPT"

echo ""
echo "  Sysprep is running. The VM will shut down automatically when done (~2-5 minutes)."
echo "  Wait until the VM shows as Stopped:"
echo "    ssh ${BASTION} 'KUBECONFIG=${KUBECONFIG_PATH} oc get vm ${VM_NAME} -n ${NS}'"
echo ""
echo "  Press Enter when the VM has stopped."
confirm

# ──────────────────────────────────────────────
# Step 11: Clone golden image PVC
# ──────────────────────────────────────────────
echo ""
echo "[11/12] Cloning root disk to golden image PVC..."

ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc apply -f -" <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${GOLDEN_PVC}
  namespace: ${NS}
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: ${ROOT_DISK_SIZE}
    storageClassName: ${ROOT_DISK_SC}
  source:
    pvc:
      namespace: ${NS}
      name: ${VM_NAME}-rootdisk
EOF

echo "  Waiting for clone to complete..."
bastion "oc wait dv ${GOLDEN_PVC} -n ${NS} --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m"
echo "  Golden image PVC ready: ${GOLDEN_PVC}"

# ──────────────────────────────────────────────
# Step 12: Create OOBE unattend secret + cleanup
# ──────────────────────────────────────────────
echo ""
echo "[12/12] Creating OOBE unattend secret and cleaning up..."

ssh "$BASTION" "KUBECONFIG=$KUBECONFIG_PATH oc apply -f -" <<OOBE_EOF
apiVersion: v1
kind: Secret
metadata:
  name: win2022-oobe-unattend
  namespace: ${NS}
type: Opaque
stringData:
  unattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <InputLocale>en-US</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideLocalAccountScreen>true</HideLocalAccountScreen>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <ProtectYourPC>3</ProtectYourPC>
          </OOBE>
          <UserAccounts>
            <AdministratorPassword><Value>${ADMIN_PASS}</Value><PlainText>true</PlainText></AdministratorPassword>
            <LocalAccounts>
              <LocalAccount wcm:action="add">
                <Name>admin</Name><Group>Administrators</Group>
                <Password><Value>${ADMIN_PASS}</Value><PlainText>true</PlainText></Password>
              </LocalAccount>
            </LocalAccounts>
          </UserAccounts>
          <AutoLogon>
            <Enabled>true</Enabled><Username>admin</Username>
            <Password><Value>${ADMIN_PASS}</Value><PlainText>true</PlainText></Password>
            <LogonCount>1</LogonCount>
          </AutoLogon>
        </component>
      </settings>
    </unattend>
OOBE_EOF

echo "  OOBE unattend secret created: win2022-oobe-unattend"

echo ""
echo "  Cleaning up installer VM and ISO..."
bastion "oc delete vm ${VM_NAME} -n ${NS} --wait=true" || true
bastion "oc delete pvc ${ISO_PVC_NAME} -n ${NS}" || true

echo ""
echo "============================================"
echo " Golden image ready!"
echo "============================================"
echo ""
echo "  PVC:    ${NS}/${GOLDEN_PVC}"
echo "  Secret: ${NS}/win2022-oobe-unattend"
echo "  Storage class: ${ROOT_DISK_SC}"
echo ""
echo "  To clone a VM from the golden image:"
echo ""
echo "    1. Create a DataVolume cloning ${GOLDEN_PVC}"
echo "       (add annotation: cdi.kubevirt.io/storage.bind.immediate.requested=true)"
echo ""
echo "    2. Create a VM with:"
echo "       - rootdisk: PVC from step 1"
echo "       - sysprep cdrom: secret win2022-oobe-unattend"
echo "         (key must be 'unattend.xml', NOT 'autounattend.xml')"
echo ""
echo "  See infra/cloud29/windows-golden-image.md for full manifest examples."
echo ""
