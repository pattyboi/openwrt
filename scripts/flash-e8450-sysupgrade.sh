#!/usr/bin/env bash
# Copy an E8450 sysupgrade image using legacy SCP, then invoke sysupgrade.
# Keep the router password out of the tree: set SSH_PASSWORD or enter it when
# prompted.  Extra arguments are passed to sysupgrade before the image path.
set -euo pipefail

target="${E8450_TARGET:-root@192.168.1.1}"

usage() {
	printf 'Usage: %s IMAGE [sysupgrade options...]\n' "$0" >&2
	printf 'Example: SSH_PASSWORD=... %s bin/targets/...-sysupgrade.itb -n\n' "$0" >&2
	exit 2
}

[[ $# -ge 1 ]] || usage
image=$1
shift
[[ -f $image ]] || { printf 'Image not found: %s\n' "$image" >&2; exit 2; }
command -v sshpass >/dev/null || { printf 'sshpass is required\n' >&2; exit 2; }

if [[ -z ${SSH_PASSWORD+x} ]]; then
	read -r -s -p "Password for ${target}: " SSH_PASSWORD
	printf '\n' >&2
fi

remote_image="/tmp/$(basename "$image")"
ssh_opts=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts")

# scp -O selects the legacy SCP protocol, required by this target workflow.
SSHPASS=$SSH_PASSWORD sshpass -e scp -O "${ssh_opts[@]}" -- "$image" "${target}:${remote_image}"

quote_remote() {
	local value=$1
	printf "'%s'" "${value//\'/\'\\\'\'}"
}

remote_command='exec sysupgrade'
for arg in "$@" "$remote_image"; do
	remote_command+=" $(quote_remote "$arg")"
done

printf 'Image copied to %s; starting sysupgrade. SSH will disconnect when it reboots.\n' "$remote_image"
SSHPASS=$SSH_PASSWORD sshpass -e ssh "${ssh_opts[@]}" "$target" "$remote_command"
