#!/bin/bash
#
# Copyright (c) 2023 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail

# shellcheck disable=SC2034
kata_tarball_dir="${2:-kata-artifacts}"
cri_containerd_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${cri_containerd_dir}/../../common.bash"

function install_system_dependencies_apt() {
	# Remove go if it's installed as it conflicts with another version of go
	sudo apt-get remove -y golang-* || true
	sudo rm -rf /usr/local/go

	# Remove Docker if it's installed as it conflicts with podman-docker
	sudo apt-get remove -y docker-ce-cli || true

	# Remove containerd if it's installed as it conflicts with another version of containerd
	sudo apt-get remove -y containerd containerd.io || true
	sudo rm -rf /etc/systemd/system/containerd.service

	# Dependency list of projects that we can rely on the system packages
	# - build-essential
	#   - Theoretically we only need `make`, but doesn't hurt to install
	#     the whole build-essential group
	# - jq
	# - podman-docker
	#   - one of the tests rely on docker to pull an image.
	#     we've decided to go for podman, instead, as it does *not* bring
	#     containerd as a dependency
	declare -a system_deps=(
		build-essential
		jq
		podman-docker
	)

	apt_get_update
	sudo apt-get -y install "${system_deps[@]}"
}

# Amazon Linux 2023, used as the parent instance for Nitro Sandboxes. It has
# no podman, and its docker package depends on a containerd package that
# would sit next to the containerd installed below, so the docker CLI that
# one of the tests needs comes from Docker's static binaries instead.
function install_system_dependencies_dnf() {
	# Remove go if it's installed as it conflicts with another version of go
	sudo dnf remove -y golang || true
	sudo rm -rf /usr/local/go

	# Remove Docker and containerd if they're installed as they conflict
	# with the containerd installed below
	sudo dnf remove -y docker containerd || true
	sudo rm -rf /etc/systemd/system/containerd.service

	# Dependency list of projects that we can rely on the system packages
	# - make, gcc: the equivalent of build-essential that the tests need
	# - jq
	# - iptables-nft: dockerd needs the iptables command
	declare -a system_deps=(
		gcc
		iptables-nft
		jq
		make
	)

	sudo dnf -y install "${system_deps[@]}"

	install_docker_static "$(get_from_kata_deps ".externals.docker.version")"
}

function install_dependencies() {
	info "Installing the dependencies needed for running the cri-containerd tests"

	if command -v apt-get > /dev/null; then
		install_system_dependencies_apt
	elif command -v dnf > /dev/null; then
		install_system_dependencies_dnf
	else
		die "No supported package manager found, apt-get or dnf is needed"
	fi

	# Dependency list of projects that we can install them
	# directly from their releases on GitHub:
	# - containerd
	#   - cri-container-cni release tarball already includes CNI plugins
	declare -a github_deps
	# shellcheck disable=SC2154
	github_deps[0]="cri_containerd:$(get_from_kata_deps ".externals.containerd.${CONTAINERD_VERSION}")"
	github_deps[1]="runc:$(get_from_kata_deps ".externals.runc.latest")"
	github_deps[2]="cni_plugins:$(get_from_kata_deps ".externals.cni-plugins.version")"

	for github_dep in "${github_deps[@]}"; do
		IFS=":" read -r -a dep <<< "${github_dep}"
		"install_${dep[0]}" "${dep[1]}"
	done

	# cri-tools is resolved at install time to the absolute latest
	# release, so it is not pinned via versions.yaml.
	install_cri_tools

	# Clone containerd as we'll need to build it in order to run the tests
	# base_version: The version to be intalled in the ${major}.${minor} format
	clone_cri_containerd "$(get_from_kata_deps ".externals.containerd.${CONTAINERD_VERSION}")"
}

function run() {
	# shellcheck disable=SC2154
	info "Running cri-containerd tests using ${KATA_HYPERVISOR} hypervisor"

	enabling_hypervisor

	bash -c "${cri_containerd_dir}/integration-tests.sh"
}

function main() {
	action="${1:-}"
	case "${action}" in
		install-dependencies) install_dependencies ;;
		install-kata) install_kata ;;
		run) run ;;
		*) >&2 die "Invalid argument" ;;
	esac
}

main "$@"
