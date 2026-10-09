# shellcheck shell=bash
# monkey-scripts/lib/env.sh — environment management: PATH seeding /
# persistence and the shell env-file infrastructure everything sits on.
# Sourced by scripts/install.sh and scripts/checkhealth.sh (BEFORE clone.sh
# and checks.sh, which rely on export_path mid-run).
#
#   bin_dirs             emits the idempotent PATH-update lines for the
#                        framework's bin-dir set (the ONE source of truth)
#   export_path          evals them (current process)
#   persist_path         appends them to the profiles (future shells)
#   export_path_pre_win / persist_brew_path — Homebrew's POSITIONAL insert
#                        (live eval / profile block; install_linuxbrew)
#   shell_env_files / append_env_block — which profile files exist and how
#                        blocks land in them (also write_tty_autostart)
#
# Priority (high → low): ~/.local/bin, cargo, go, npm — on name collisions
# compiled implementations beat Node-CLI ones, and ~/.local/bin carries
# explicit user intent (hand-placed binaries + the _brew_first_link
# symlinks). Homebrew goes AFTER the system paths (its python@3.x used to
# hide /usr/bin/python3) and BEFORE the WSL shims, and persists even when
# PERSIST_PATH=0 (see persist_brew_path — the reason it is NOT part of
# persist_path: its positional insert cannot be a prepend case-line).

# Homebrew's bin dirs. Inserted positionally (see export_path_pre_win),
# never prepended.
BREW_BIN_DIRS="/home/linuxbrew/.linuxbrew/bin /opt/homebrew/bin"

# ────────────────────── shell env files ──────────────────────
shell_env_files() {
	# The TARGET login shell decides WHICH profile files: zsh → ~/.zprofile;
	# bash → ~/.bash_profile (or ~/.profile) + ~/.bashrc. Falls back to
	# $SHELL, then bash (macOS has no getent; its $SHELL already reflects
	# the login shell).
	local shell_bin
	# No getent on macOS — guard the call (a bare 127 would trip set -e
	# before the dscl fallback below ever runs).
	if have_native_cmd getent; then
		shell_bin=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
	fi
	if [ -z "$shell_bin" ] && [ "$(uname -s)" = Darwin ]; then
		# $SHELL is a login-time snapshot and goes stale right after a chsh.
		shell_bin=$(dscl . -read /Users/"$(id -un)" UserShell 2>/dev/null | awk '{print $2}')
	fi
	shell_bin=${shell_bin:-${SHELL:-bash}}
	shell_bin=${shell_bin##*/}
	case "$shell_bin" in
	zsh)
		printf '%s\n' "$HOME/.zprofile"
		;;
	bash)
		if [ -f "$HOME/.bash_profile" ]; then
			printf '%s\n' "$HOME/.bash_profile"
		else
			printf '%s\n' "$HOME/.profile"
		fi
		printf '%s\n' "$HOME/.bashrc"
		;;
	*)
		printf '%s\n' "$HOME/.profile"
		;;
	esac
}

append_env_block() {
	# Usage: append_env_block <marker> <block>
	# Appends <block> guarded by <marker> to every shell env file, once.
	local marker="$1"
	local block="$2"
	local f
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		[ -f "$f" ] || touch "$f"
		if ! grep -qF -- "$marker" "$f" 2>/dev/null; then
			printf '\n# %s\n%b\n' "$marker" "$block" >>"$f"
			ok "Added '$marker' to $f"
		fi
	done < <(shell_env_files)
}

# ────────────────────── bin dirs / PATH ──────────────────────
# bin_dirs — the ONE source of truth for the framework's bin-dir set;
# emits idempotent PATH-update lines, LOW → HIGH priority order (consumers
# prepend in yield order, so the LAST emitted dir ends up first on PATH —
# the first GOPATH entry emits last among the go dirs). Resolution mirrors
# the tools (pure parameter expansion — no `go env` subprocess):
#   GOBIN, else every GOPATH entry's bin, else ~/go/bin ($HOME stays
#   literal — eval and the profile expand it identically);
#   ${CARGO_HOME:-$HOME/.cargo}/bin — resolved INSIDE the emitted line;
#   plus the user-local ~/.local/bin and ~/.npm-global/bin.
# (/usr/local/bin is deliberately absent: a system path the default PATH
# already carries.)
# Consumers apply their own policy:
#   export_path  — eval: export every dir, existing or not
#   persist_path — append_env_block: one case-line per dir (unconditional:
#                  a not-yet-existing dir is future-proofing, not noise)
bin_dirs() {
	local -a go_dirs=()
	if [ -n "${GOBIN:-}" ]; then
		go_dirs+=("$GOBIN")
	else
		# Split GOPATH on ':' ONLY (a temporarily narrowed IFS, restored
		# right after — paths with spaces survive as whole entries). The
		# escaped default keeps $HOME literal for the common layout.
		local gopath_entry old_ifs=$IFS
		IFS=':'
		for gopath_entry in ${GOPATH:-\$HOME/go}; do
			go_dirs+=("$gopath_entry/bin")
		done
		IFS=$old_ifs
	fi
	printf '%s\n' 'case ":$PATH:" in *":$HOME/.npm-global/bin:"*) ;; *) export PATH="$HOME/.npm-global/bin:$PATH" ;; esac'
	local d
	for d in ${go_dirs[@]+"${go_dirs[@]}"}; do
		printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$d" "$d"
	done
	printf '%s\n' 'case ":$PATH:" in *":${CARGO_HOME:-$HOME/.cargo}/bin:"*) ;; *) export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH" ;; esac'
	printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
}

export_path() {
	# No [ -d ] filter: not-yet-existing dirs (rustup's ~/.cargo/bin at
	# startup, GOPATH/bin before the first install) are seeded anyway and
	# resolve the moment a binary lands in them — no re-seeds mid-run.
	eval "$(bin_dirs)"
	# Brew tier: AFTER system paths, BEFORE the WSL shims (see header).
	local d
	for d in $BREW_BIN_DIRS; do
		export_path_pre_win "$d"
	done
}

persist_path() {
	# The SAME lines export_path evals — written to the profiles verbatim;
	# the case guards re-check at shell startup.
	# shellcheck disable=SC2016 # $PATH must stay literal in the block
	append_env_block "user-local bin dirs (framework installer)" "$(bin_dirs)"
	ok "PATH persistence added for the user-local framework bin dirs (~/.local/bin, GOBIN/GOPATH/cargo/npm-global — see bin_dirs)."
	# Brew dirs are persist_brew_path's business (positional; runs even
	# when PERSIST_PATH=0).
}

# persist_brew_path <brew_prefix> — Homebrew's profile block, called by
# install_linuxbrew at install/adopt time. Separate from persist_path:
# POSITIONAL insertion that a prepend case-line cannot express, and it
# runs even when PERSIST_PATH=0. The block embeds a SNAPSHOT of
# export_path_pre_win (renamed, called for bin and sbin, then unset -f) —
# the algorithm lives ONCE in the live function; keep its body
# POSIX-portable (the profile may run under zsh or ~/.profile's sh) and
# namespace-clean (the copy is unset after use).
persist_brew_path() {
	local brew_prefix="$1"
	# One call, one block: bin and sbin are a unit (guard keyed on bin).
	local block
	block=$(_path_pre_win_snippet "$brew_prefix/bin" "$brew_prefix/sbin")
	append_env_block "Homebrew PATH (before Windows shims)" "$block"
}

# _path_pre_win_snippet <dir>... — the ONE rendering of the positioning
# algorithm for a GROUP of dirs installed as a unit (brew's bin+sbin):
# insert the group before the FIRST /mnt entry; front when /mnt is the
# first entry; append when there is no /mnt section. Any group dir already
# present skips the whole group. POSIX text, dirs baked in, $PATH left
# LIVE — export_path_pre_win evals it, persist_brew_path bakes it into the
# profile.
_path_pre_win_snippet() {
	[ $# -gt 0 ] || return 0
	local gtext="" group="" d
	for d in "$@"; do
		gtext+=$'\n*":'"$d"':"*) ;;'
		group+="${group:+:}$d"
	done
	# shellcheck disable=SC2016 # $PATH/$p must stay literal in the snippet
	local s='case ":$PATH:" in'"$gtext"'
:/mnt/* | ":/mnt:") PATH="'"$group"':$PATH" ;;
*":/mnt/"*)
	p=${PATH%%:/mnt/*}
	PATH="$p:'"$group"':${PATH#"$p":}" ;;
*) PATH="$PATH:'"$group"'" ;;
esac'
	printf '%s\n' "$s"
}

export_path_pre_win() {
	# The snippet assigns PATH (already exported — the assignment keeps the
	# export attribute); its trailing `unset p` cleans up after the /mnt
	# arm, so nothing leaks into the caller's environment.
	eval "$(_path_pre_win_snippet "$@")"
}
