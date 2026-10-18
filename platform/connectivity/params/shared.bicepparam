using '../main.bicep'

param addressPrefix = '10.0.0.0/22'
param tags = {
  workload: 'hub-spoke'
}
// Router VM SSH public key, read at deploy time so it stays out of the repo (see "SSH key" in CLAUDE.md).
// Create once:   ssh-keygen -t ed25519 -f "$HOME\.ssh\azure-hub-spoke-template-01" -C "azure-hub-spoke-template-01"
// Before deploy: $env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"
param adminSshPublicKey = readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')
