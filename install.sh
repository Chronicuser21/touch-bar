#!/usr/bin/env bash
set -euo pipefail

# NixOS keeps no /usr/bin, so find every tool in a fixed system-directory
# list first (NixOS's setuid wrappers and system profile, then the usual FHS
# layouts), falling back to PATH only for ad-hoc installs such as a nix shell
# or a local build. /run/wrappers/bin has the setuid sudo, which is required
# on NixOS; /run/current-system/sw/bin/sudo is a plain store binary that
# refuses to raise privileges.
find_tool () {
  local name=$1 path
  for path in /run/wrappers/bin /run/current-system/sw/bin \
              /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    if [[ -x $path/$name ]]; then
      printf '%s\n' "$path/$name"
      return 0
    fi
  done
  if path=$(command -v "$name" 2>/dev/null); then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

declare -A BIN
required=(python3 hyprctl systemctl wtype rsvg-convert brightnessctl wpctl \
          tiny-dfr install sudo grep sed touch cmp id chown chgrp chmod \
          udevadm pkill rm)
for name in "${required[@]}"; do
  if ! BIN[$name]=$(find_tool "$name"); then
    echo "Missing required command: $name" >&2
    exit 1
  fi
done

script_path=${BASH_SOURCE[0]}
[[ $script_path == /* ]] || script_path=$PWD/$script_path
project_dir=$(cd -- "${script_path%/*}" && pwd -P)

if [[ $("${BIN[id]}" -u) -eq 0 ]]; then
  echo "Run install.sh as your normal user, not via sudo: user-level files" >&2
  echo "land in \$HOME, and the few privileged steps call sudo themselves." >&2
  exit 1
fi

me=$("${BIN[id]}" -un)
mygroup=$("${BIN[id]}" -gn)
# NixOS's /etc is generated (partly read-only store links), so writable-free
# system steps are handled declaratively; detect it for those branches.
nixos=false
if [[ -e /run/current-system && -d /run/current-system ]]; then
  nixos=true
fi

user_bin="${HOME}/.local/bin"
omarchy_config="${HOME}/.config/omarchy"
hypr_config="${HOME}/.config/hypr"
user_systemd="${HOME}/.config/systemd/user"
force_config=false

if [[ "${1:-}" == "--force-config" ]]; then
  force_config=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: ./install.sh [--force-config]" >&2
  exit 2
fi

"${BIN[install]}" -d "$user_bin" "$omarchy_config" "$omarchy_config/hooks/theme-set.d" "$hypr_config" "$user_systemd"
"${BIN[install]}" -m 0755 "$project_dir/src/omarchy-touchbar" "$user_bin/omarchy-touchbar"
"${BIN[install]}" -m 0755 "$project_dir/src/omarchy-chatgpt-dictate" "$user_bin/omarchy-chatgpt-dictate"
"${BIN[install]}" -m 0755 "$project_dir/src/omarchy-touchbar-settings" "$user_bin/omarchy-touchbar-settings"
"${BIN[install]}" -d "${HOME}/.local/share/applications"
"${BIN[install]}" -m 0644 "$project_dir/integration/omarchy-touchbar-settings.desktop" \
  "${HOME}/.local/share/applications/omarchy-touchbar-settings.desktop"
"${BIN[install]}" -m 0755 "$project_dir/integration/theme-set-touchbar" \
  "$omarchy_config/hooks/theme-set.d/touchbar"
"${BIN[install]}" -m 0644 "$project_dir/integration/omarchy-touchbar.service" \
  "$user_systemd/omarchy-touchbar.service"

if $force_config || [[ ! -e "$omarchy_config/touchbar.toml" ]]; then
  "${BIN[install]}" -m 0644 "$project_dir/config/touchbar.toml" "$omarchy_config/touchbar.toml"
else
  "${BIN[install]}" -m 0644 "$project_dir/config/touchbar.toml" "$omarchy_config/touchbar.toml.dist"
  echo "Kept existing touchbar.toml; repository version installed as touchbar.toml.dist."
fi

autostart="$hypr_config/autostart.lua"
"${BIN[touch]}" "$autostart"
if "${BIN[grep]}" -Fq 'o.launch_on_start("systemctl --user start omarchy-touchbar.service")' "$autostart"; then
  "${BIN[sed]}" -i "s|o.launch_on_start(\"systemctl --user start omarchy-touchbar.service\")|o.launch_on_start(\"${BIN[systemctl]} --user start omarchy-touchbar.service\")|" "$autostart"
elif "${BIN[grep]}" -Fq "o.launch_on_start(\"${BIN[systemctl]} --user start omarchy-touchbar.service\")" "$autostart"; then
  :
elif "${BIN[grep]}" -Fq 'systemd-run --user --unit=omarchy-touchbar' "$autostart"; then
  "${BIN[sed]}" -i 's|o.launch_on_start("systemd-run --user --unit=omarchy-touchbar --collect " .. os.getenv("HOME") .. "/.local/bin/omarchy-touchbar daemon")|o.launch_on_start("'"${BIN[systemctl]}"' --user start omarchy-touchbar.service")|' "$autostart"
elif "${BIN[grep]}" -Fq 'omarchy-touchbar daemon' "$autostart"; then
  "${BIN[sed]}" -i 's|o.launch_on_start(os.getenv("HOME") .. "/.local/bin/omarchy-touchbar daemon")|o.launch_on_start("'"${BIN[systemctl]}"' --user start omarchy-touchbar.service")|' "$autostart"
else
  printf '\n-- Context-aware T2 MacBook Touch Bar.\n' >> "$autostart"
  printf 'o.launch_on_start("%s --user start omarchy-touchbar.service")\n' "${BIN[systemctl]}" >> "$autostart"
fi

bindings="$hypr_config/bindings.lua"
"${BIN[touch]}" "$bindings"
if ! "${BIN[grep]}" -Fq 'Touch Bar daemon-owned controls' "$bindings"; then
  while IFS= read -r line; do printf '%s\n' "$line"; done >> "$bindings" <<'LUA'

-- Touch Bar daemon-owned controls use the raw touch surface, not F-keys.
for key = 13, 24 do
  hl.unbind("F" .. tostring(key))
end
LUA
fi

if [[ ! -d /etc/tiny-dfr || ! -w /etc/tiny-dfr ]]; then
  echo "Preparing /etc/tiny-dfr for live user-level rendering (sudo required)."
  "${BIN[sudo]}" "${BIN[install]}" -d -m 0755 -o "$me" -g "$mygroup" /etc/tiny-dfr /etc/tiny-dfr/gen
  if $nixos && [[ -L /etc/tiny-dfr/config.toml ]]; then
    # On NixOS /etc/tiny-dfr/config.toml is a read-only symlink into the store
    # (hardware.apple.touchBar.settings). Drop it so the daemon can own a live
    # file and rewrite it in place.
    "${BIN[sudo]}" "${BIN[rm]}" -f /etc/tiny-dfr/config.toml
  fi
  "${BIN[sudo]}" "${BIN[touch]}" /etc/tiny-dfr/config.toml
  "${BIN[sudo]}" "${BIN[chown]}" "$me:$mygroup" /etc/tiny-dfr/config.toml
  if $nixos; then
    echo "  (NixOS: a nixos-rebuild re-links config.toml into the store; import"
    echo "   nixos/touchbar.nix so tmpfiles keeps it live and user-owned.)"
  fi
fi

backlight_rule=/etc/udev/rules.d/99-touchbar-backlight.rules
if $nixos; then
  if [[ ! -e $backlight_rule ]]; then
    echo "Skipping the backlight udev rule (NixOS generates /etc/udev/rules.d)."
    echo "Declare services.udev.extraRules via the bundled nixos/touchbar.nix."
  fi
elif [[ ! -e $backlight_rule ]]; then
  echo "Allowing the session to hold the Touch Bar backlight on (sudo required)."
  bin_dir=$(dirname "${BIN[chgrp]}")
  tmp_rules=$(mktemp)
  trap 'rm -f "$tmp_rules"' EXIT
  "${BIN[sed]}" "s|@@BIN@@|${bin_dir}|g" "$project_dir/integration/99-touchbar-backlight.rules" > "$tmp_rules"
  "${BIN[sudo]}" "${BIN[install]}" -m 0644 "$tmp_rules" "$backlight_rule"
  "${BIN[sudo]}" "${BIN[udevadm]}" control --reload-rules
  "${BIN[sudo]}" "${BIN[chgrp]}" input /sys/class/backlight/appletb_backlight/brightness
  "${BIN[sudo]}" "${BIN[chmod]}" g+w /sys/class/backlight/appletb_backlight/brightness
fi

panel_reset=/usr/local/lib/touchbar-panel-reset
if $nixos; then
  echo "Skipping the post-resume panel reset (no writable /etc/systemd on NixOS)."
  echo "Declare systemd.services.touchbar-panel-reset via the bundled"
  echo "nixos/touchbar.nix module."
elif [[ ! -e $panel_reset ]] \
    || ! "${BIN[cmp]}" -s "$project_dir/integration/touchbar-panel-reset" "$panel_reset"; then
  echo "Installing the post-resume Touch Bar display reset (sudo required)."
  "${BIN[sudo]}" "${BIN[install]}" -m 0755 "$project_dir/integration/touchbar-panel-reset" "$panel_reset"
  "${BIN[sudo]}" "${BIN[install]}" -m 0644 "$project_dir/integration/touchbar-panel-reset.service" \
    /etc/systemd/system/touchbar-panel-reset.service
  "${BIN[sudo]}" "${BIN[systemctl]}" daemon-reload
  "${BIN[sudo]}" "${BIN[systemctl]}" enable touchbar-panel-reset.service
fi

"${BIN[python3]}" -m py_compile "$user_bin/omarchy-touchbar" "$user_bin/omarchy-chatgpt-dictate" \
  "$user_bin/omarchy-touchbar-settings"
"${BIN[python3]}" -c 'import tomllib, pathlib; tomllib.loads(pathlib.Path.home().joinpath(".config/omarchy/touchbar.toml").read_text())'

"${BIN[systemctl]}" --user stop omarchy-touchbar.service 2>/dev/null || true
# Also reap any daemon launched outside the unit (pre-unit autostart entries).
"${BIN[pkill]}" -f "$user_bin/omarchy-touchbar daemon" 2>/dev/null || true
"${BIN[systemctl]}" --user daemon-reload
"${BIN[systemctl]}" --user enable omarchy-touchbar.service >/dev/null
"${BIN[systemctl]}" --user restart omarchy-touchbar.service
"${BIN[sudo]}" "${BIN[systemctl]}" restart tiny-dfr
"${BIN[hyprctl]}" reload >/dev/null

echo "Omarchy Touch Bar installed and running."
echo "Run: omarchy-touchbar status"
if $nixos; then
  echo
  echo "NixOS: keep the system pieces across nixos-rebuild by importing"
  echo "  $project_dir/nixos/touchbar.nix"
  echo "from configuration.nix and setting"
  echo "  services.omarchyTouchbar = { enable = true; user = \"$me\"; };"
fi
